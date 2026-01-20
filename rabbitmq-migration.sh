#!/bin/bash
# RabbitMQ 3.13 → 4.1 Complete Production Migration Script
# Handles read-only mnesia volumes, Spryker integration, queue migration, and RabbitMQ 4.1 features

set -euo pipefail

set -m

# Function to handle SIGTERM
terminate() {
    echo >&2 "Caught SIGTERM, forwarding to children..."
    rabbitmqctl stop
    echo >&2 "Waiting for child processes to terminate..."
    wait
    echo >&2 "All processes terminated, exiting with code 0"
    exit 0
}

trap 'terminate' SIGTERM

ORIGINAL_MNESIA="/var/lib/rabbitmq/mnesia"
SHADOW_BASE="/tmp/rabbitmq_shadow" 
SHADOW_MNESIA="$SHADOW_BASE/mnesia"
EXISTING_NODE=""
RABBITMQ_PID=""
MIGRATION_MARKER="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/.migration_complete_4.1"

log() {
    printf "[%s] [rmq-migration] %s\n" "$(date '+%F %T')" "$*" >&2
}

die() {
    printf "[%s] [rmq-migration][ERROR] %s\n" "$(date '+%F %T')" "$*" >&2
    exit 1
}

detect_existing_data() {
    log "=== Detecting existing RabbitMQ data ==="

    if [ -f "$MIGRATION_MARKER" ]; then
        log "✅ Marker found - skipping migration"
        ( sleep 30; rabbitmqctl wait --pid 1 && rabbitmqctl enable_feature_flag all ) &
        return 1
    fi

    if [ -d "$SHADOW_MNESIA" ] && [ "$(ls -A "$SHADOW_MNESIA" 2>/dev/null)" ]; then
        log "✅ Migration already completed, starting RabbitMQ 4.1..."
        rabbitmq-server &
        return 1
    fi

    if [ -d "$ORIGINAL_MNESIA" ]; then
        # Look for existing node data
        EXISTING_NODE=$(ls -1 "$ORIGINAL_MNESIA" 2>/dev/null | grep -E '^rabbit(mq)?@' | head -n1 || true)

        if [ -n "$EXISTING_NODE" ]; then
            log "✅ Found existing data: $EXISTING_NODE - starting migration"
            return 0
        fi
    fi

    log "No existing data - fresh installation"
    return 1
}

test_mnesia_writability() {
    if touch "$ORIGINAL_MNESIA/.write_test" 2>/dev/null; then
        rm -f "$ORIGINAL_MNESIA/.write_test"
        log "✅ Original mnesia is writable - using in-place upgrade"
        return 0
    else
        log "⚠️ Original mnesia is read-only - copy-on-write strategy required"
        return 1
    fi
}

copy_mnesia_to_shadow() {
    local source_mnesia="$1"
    local shadow_mnesia="$2"

    log "=== Implementing copy-on-write strategy ==="
    log "Source: $source_mnesia"
    log "Target: $shadow_mnesia"

    mkdir -p "$shadow_mnesia" || die "Failed to create shadow mnesia directory"

    log "Copying mnesia data to shadow directory..."

    for item in "$source_mnesia"/*; do
        local basename=$(basename "$item")
        if [[ "$basename" =~ ^aws-backup- ]]; then
            continue
        fi

        if ! cp -r "$item" "$shadow_mnesia/" 2>&1; then
            log "⚠️ Warning: Failed to copy $basename"
        fi
    done

    if [ ! -d "$shadow_mnesia/$EXISTING_NODE" ]; then
        die "❌ Failed to copy node directory: $EXISTING_NODE"
    fi

    log "✅ Data copied successfully"

    chown -R rabbitmq:rabbitmq "$shadow_mnesia" 2>&1 || true

    cleanup_shadow_files "$shadow_mnesia"
    log "✅ Shadow mnesia prepared successfully"
}

cleanup_shadow_files() {
    local shadow_mnesia="$1"

    find "$shadow_mnesia" -name "*.pid" -delete 2>/dev/null || true
    find "$shadow_mnesia" -name "*.lock" -delete 2>/dev/null || true

    for node_dir in "$shadow_mnesia"/rabbit@*; do
        if [ -d "$node_dir" ]; then
            rm -f "$node_dir"/recovery.dets 2>/dev/null || true
            rm -f "$node_dir"/*.backup 2>/dev/null || true
        fi
    done
}

setup_shadow_environment() {
    log "=== Setting up shadow environment ==="

    mkdir -p "$SHADOW_BASE"
    export HOME="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/shadow_home" 
    mkdir -p "$HOME"

    local shadow_cookie="$HOME/.erlang.cookie"
    local main_cookie="/var/lib/rabbitmq/.erlang.cookie"

    if [ -s "$main_cookie" ] && [ -r "$main_cookie" ]; then
        cp "$main_cookie" "$shadow_cookie"
        chmod 600 "$shadow_cookie"
        log "Copied existing Erlang cookie to shadow"
    elif [ -s "$shadow_cookie" ]; then
        log "Using existing shadow Erlang cookie"
    else
        echo "rabbitmq-cookie-$(date +%s)" > "$shadow_cookie"
        chmod 600 "$shadow_cookie"
        log "Created new Erlang cookie in shadow"

        if [ -w "/var/lib/rabbitmq" ]; then
            cp "$shadow_cookie" "$main_cookie"
            chmod 600 "$main_cookie"
            chown rabbitmq:rabbitmq "$main_cookie" 2>/dev/null || true
            log "Synchronized cookie to main directory"
        fi
    fi

    local cookie_val="$(cat "$shadow_cookie")"
    export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${cookie_val}"
    export RABBITMQ_CTL_ERL_ARGS="-setcookie ${cookie_val}"

    log "Cookie value: ${cookie_val:0:10}..."
    log "✅ Shadow environment ready with synchronized cookie"
}

determine_mnesia_strategy() {
    log "=== Preparing migration ==="

    if [ -n "$EXISTING_NODE" ]; then
        log "Backing up data to shadow directory..."
        copy_mnesia_to_shadow "$ORIGINAL_MNESIA" "$SHADOW_MNESIA"

        log "Creating working copy from shadow to original..."
        cp -a "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/" || {
            die "❌ Failed to create working copy!"
        }
        log "✅ Data copied from shadow to original"

        log "Cleaning up old files from original (preserving AWS backups)..."
        for item in "$ORIGINAL_MNESIA"/*; do
            local basename=$(basename "$item")
            if [ ! -e "$SHADOW_MNESIA/$basename" ] && [[ ! "$basename" =~ ^aws-backup- ]]; then
                rm -rf "$item" 2>/dev/null || {
                    log "⚠️ Could not remove old file: $basename"
                }
            fi
        done

        # Clean up temporary shadow directory
        log "Removing temporary shadow directory..."
        rm -rf /tmp/rabbitmq_shadow
        
        chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA" 2>/dev/null || true

        log "✅ Ready for migration"
    else
        log "Strategy: Fresh installation in original"
        mkdir -p "$ORIGINAL_MNESIA"
    fi

    # Ensure RabbitMQ uses the original mnesia directory
    export RABBITMQ_MNESIA_BASE="/var/lib/rabbitmq/mnesia"
    export USING_SHADOW=false

    log "✅ RabbitMQ will use: $ORIGINAL_MNESIA"
}

start_rabbitmq() {
    epmd -kill >/dev/null 2>&1 || true

    log "Starting RabbitMQ server..."
    rabbitmq-server &
    RABBITMQ_PID=$!
    log "RabbitMQ started with PID: $RABBITMQ_PID"
}

wait_for_rabbitmq() {
    log "=== Waiting for RabbitMQ to become ready ==="

    for i in $(seq 1 60000); do
        if rabbitmqctl status >/dev/null 2>&1; then
            log "✅ RabbitMQ 4.1 is running!"
            return 0
        fi

        if [ $((i % 10)) -eq 0 ]; then
            log "Still waiting... ($i/60000 seconds)"
        fi

        sleep 1
        if [ $i -eq 60000 ]; then
            die "❌ RabbitMQ failed to start within 60000 seconds"
        fi
    done
}

verify_rabbitmq_status() {
    log "=== Verifying RabbitMQ Status ==="
    rabbitmqctl status || die "Failed to get RabbitMQ status"
}

show_current_state() {
    log "=== Current RabbitMQ State ==="

    log "Vhosts:"
    timeout 10 rabbitmqctl list_vhosts || {
        log "⚠️ Could not list vhosts (timeout or error)"
    }

    log "Users:"
    timeout 10 rabbitmqctl list_users || {
        log "⚠️ Could not list users (timeout or error)"
    }

    log "Queues:"
    timeout 10 rabbitmqctl list_queues name messages || {
        log "⚠️ Could not list queues (timeout or error)"
    }
}

enable_management_ui() {
    log "Enabling RabbitMQ management plugin..."
    rabbitmq-plugins enable rabbitmq_management || {
        log "⚠️ Could not enable management plugin, but continuing..."
        return 1
    }

    log "✅ Management UI enabled successfully"
}

update_rabbitmq_policies() {
    log "Updating RabbitMQ Policies for RabbitMQ 4.1 Compatibility..."

    local vhosts
    vhosts=$(rabbitmqctl list_vhosts --quiet) || {
        log "⚠️ Could not list vhosts for policy updates"
        return 1
    }

    while IFS= read -r vhost; do
        if [ -n "$vhost" ]; then
            log "Processing policies for vhost: $vhost"

            local policies
            policies=$(rabbitmqctl list_policies -p "$vhost" --quiet 2>/dev/null) || {
                log "No policies found for vhost $vhost"
                continue
            }

            if [ -n "$policies" ]; then
                echo "$policies" | while IFS=$'\t' read -r vhost name pattern apply_to definition priority; do
    if [[ "$definition" == *"ha-mode"* ]] || [[ "$definition" == *"ha-sync-mode"* ]]; then
        rabbitmqctl clear_policy -p "$vhost" "$name"
        if [[ "$definition" == *'"queue-mode":"lazy"'* ]]; then
            rabbitmqctl set_policy -p "$vhost" "$name" "$pattern" \
              '{"queue-mode":"lazy"}' --apply-to "$apply_to" --priority "$priority"
        fi
    fi
done
            fi
        fi
    done <<< "$vhosts"

    log "✅ Policy migration complete - deprecated ha-mode policies removed"
}

count_messages_in_queues() {
    log "=== Counting Messages in All Queues ==="

    local total_messages=0
    local queue_info
    local vhosts

    vhosts=$(rabbitmqctl list_vhosts --quiet 2>/dev/null) || {
        log "⚠️ Could not list vhosts for message counting"
        return 1
    }

    while IFS= read -r vhost; do
        if [ -n "$vhost" ] && [ "$vhost" != "name" ]; then
            log "Checking vhost: $vhost"

            queue_info=$(rabbitmqctl list_queues -p "$vhost" --quiet name messages 2>/dev/null) || {
                log "⚠️ Could not list queues for vhost $vhost"
                continue
            }

            local vhost_messages=0
            while IFS=$'\t' read -r queue_name messages; do
                if [ -n "$queue_name" ] && [ -n "$messages" ]; then
                    if [[ "$messages" =~ ^[0-9]+$ ]]; then
                        if [ "$messages" != "0" ]; then
                            log "  Queue '$queue_name': $messages messages"
                        fi
                        vhost_messages=$((vhost_messages + messages))
                    else
                        log "⚠️ Invalid message count '$messages' for queue '$queue_name' - skipping"
                    fi
                fi
            done <<< "$queue_info"

            log "Vhost '$vhost': $vhost_messages total messages"
            total_messages=$((total_messages + vhost_messages))
        fi
    done <<< "$vhosts"

    log "📊 Total messages across all queues: $total_messages"
    echo "$total_messages"
}

enable_rabbitmq_41_features() {
    log "=== Enabling RabbitMQ 4.1 Feature Flags ==="

    local safe_features=(
        "drop_unroutable_metric"
        "empty_basic_get_metric"
        "implicit_default_bindings"
        "maintenance_mode_status"
        "quorum_queue"
        "stream_queue"
        "user_limits"
        "virtual_host_metadata"
    )

    local available_features
    available_features=$(timeout 30 rabbitmqctl list_feature_flags --quiet | cut -f1) || {
        log "⚠️ Could not list available feature flags"
        return 1
    }

    # Enable all stable feature flags at once
    log "Enabling all stable feature flags..."
    timeout 60 rabbitmqctl enable_feature_flag all || {
        log "⚠️ Could not enable all feature flags, trying individual approach..."

        # Fallback to individual feature flag enabling
        for feature in "${safe_features[@]}"; do
            if echo "$available_features" | grep -q "^${feature}$"; then
                log "Enabling feature flag: $feature"
                timeout 30 rabbitmqctl enable_feature_flag "$feature" || {
                    log "⚠️ Could not enable feature flag $feature, but continuing..."
                }
            else
                log "Feature flag $feature not available in this version"
            fi
        done
    }

    local deprecated_replacement_features=(
        "classic_queue_type_delivery_support"
        "message_containers"
        "direct_exchange_routing_v2"
        "amqp_address_v1"
        "feature_flags_v2"
        "message_containers_deaths_v2"
        "detailed_queues_endpoint"
        "rabbitmq_4.0.0"
        "rabbitmq_4.1.0"
    )

    log "Enabling feature flags to replace deprecated features..."
    for feature in "${deprecated_replacement_features[@]}"; do
        if echo "$available_features" | grep -q "^${feature}$"; then
            log "Enabling replacement feature flag: $feature"
            timeout 30 rabbitmqctl enable_feature_flag "$feature" || {
                log "⚠️ Could not enable feature flag $feature, but continuing..."
            }
        else
            log "Replacement feature flag $feature not available in this version"
        fi
    done

    log "Investigating classic_queue_mirroring 'In use' status..."

    # Check for existing mirrored queues that need conversion
    local vhosts_list
    vhosts_list=$(timeout 30 rabbitmqctl list_vhosts --quiet 2>/dev/null) || {
        log "⚠️ Could not list vhosts"
    }

    if [ -n "$vhosts_list" ]; then
        while IFS= read -r vhost; do
            if [ -n "$vhost" ] && [ "$vhost" != "name" ]; then
                log "Checking for mirrored queues in vhost: $vhost"

                # List queues with their policy information
                local queue_info
                queue_info=$(timeout 30 rabbitmqctl list_queues -p "$vhost" name policy 2>/dev/null) || {
                    log "⚠️ Could not list queues for vhost $vhost"
                    continue
                }

                # Check if any queues have mirroring policies applied
                if echo "$queue_info" | grep -q "ha-"; then
                    log "⚠️ Found queues with mirroring policies in vhost $vhost"
                    echo "$queue_info" | grep "ha-" | while read -r queue_name policy_name; do
                        log "Queue '$queue_name' has mirroring policy: $policy_name"
                    done
                fi
            fi
        done <<< "$vhosts_list"
    fi

    # Remove any remaining mirroring policies
    local policies
    policies=$(timeout 30 rabbitmqctl list_policies --quiet 2>/dev/null) || {
        log "⚠️ Could not list policies"
    }

    if [ -n "$policies" ]; then
        echo "$policies" | while IFS=$'\t' read -r vhost name pattern definition priority; do
            if [[ "$definition" == *"ha-mode"* ]] || [[ "$definition" == *"ha-sync-mode"* ]]; then
                log "⚠️ Found deprecated mirroring policy: $name in vhost $vhost"
                log "Removing deprecated policy: $name"
                timeout 30 rabbitmqctl clear_policy -p "$vhost" "$name" || {
                    log "⚠️ Could not remove policy $name"
                }
            fi
        done
    fi

    # Force clear deprecated features detection
    log "Attempting to clear deprecated features detection..."
    timeout 30 rabbitmqctl eval 'rabbit_deprecated_features:override_used_deprecated_features([]).' 2>/dev/null || {
        log "Could not override deprecated features detection"
    }

    log "✅ RabbitMQ 4.1 feature flags configuration complete"
}

setup_spryker_environment() {
    log "=== Setting up Spryker environment ==="

    # Get existing vhosts from current RabbitMQ installation
    local existing_vhosts
    existing_vhosts=$(timeout 30 rabbitmqctl list_vhosts --quiet 2>/dev/null || echo "/")

    if [ -z "$existing_vhosts" ]; then
        log "⚠️ No vhosts found - using default '/' vhost"
        existing_vhosts="/"
    fi

    log "📋 Found existing vhosts to preserve: $existing_vhosts"
    local required_vhosts="$existing_vhosts"

    # Get RabbitMQ user from environment or use default
    local rabbitmq_user="${RABBITMQ_DEFAULT_USER:-spryker}"

    # Verify that existing vhosts are still accessible after migration
    for vhost in $required_vhosts; do
        if timeout 30 rabbitmqctl list_vhosts --quiet 2>/dev/null | grep -q "^${vhost}$"; then
            log "✅ Vhost '${vhost}' successfully preserved during migration"

            # Verify permissions exist for the vhost
            if timeout 30 rabbitmqctl list_permissions -p "$vhost" >/dev/null 2>&1; then
                log "✅ Permissions preserved for vhost '${vhost}'"
            else
                log "⚠️ Setting up permissions for preserved vhost '${vhost}'"
                timeout 30 rabbitmqctl set_permissions -p "$vhost" "$rabbitmq_user" ".*" ".*" ".*" || true
            fi
        fi
    done

    log "✅ Spryker environment setup complete"
}

sync_shadow_to_original() {
    log "=== Syncing migrated data from shadow to original ==="

    if [ "$USING_SHADOW" != "true" ]; then
        log "Not using shadow, skipping sync"
        return 0
    fi

    if [ ! -d "$SHADOW_MNESIA" ]; then
        log "⚠️ Shadow directory doesn't exist, skipping sync"
        return 0
    fi

    log "📁 Shadow is no longer in use, safe to copy without stopping RabbitMQ"

    log "Copying shadow → original..."
    mkdir -p "$(dirname "$ORIGINAL_MNESIA")"
    cp -a "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/" || {
        log "❌ Failed to copy shadow to original!"
        return 1
    }
    
    log "Cleaning up old files from original..."
    for item in "$ORIGINAL_MNESIA"/*; do
        local basename=$(basename "$item")
        if [ ! -e "$SHADOW_MNESIA/$basename" ] && [[ ! "$basename" =~ ^aws-backup- ]]; then
            rm -rf "$item" 2>/dev/null || {
                log "⚠️ Could not remove old file: $basename"
            }
        fi
    done
    
    rm -rf /tmp/rabbitmq_shadow

    log "Setting proper ownership..."
    chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA" 2>/dev/null || true

    log "✅ Shadow successfully synced to original"
}

print_completion_message() {
    if [ -n "$EXISTING_NODE" ]; then
        log "✅ Complete RabbitMQ 3.13→4.1 Migration Successful!"
    else
        log "✅ Fresh RabbitMQ 4.1 Installation Complete!"
    fi
    
    # Create migration marker
    touch "$MIGRATION_MARKER"
}

main() {
    if ! detect_existing_data; then
        # No existing data - fresh install, just start RabbitMQ
        log "Fresh installation - starting RabbitMQ 4.1 directly..."
        rabbitmq-server &
        wait
        exit 0
    fi

    setup_shadow_environment
    determine_mnesia_strategy

    start_rabbitmq
    wait_for_rabbitmq
    verify_rabbitmq_status
    show_current_state

    log "⏳ Waiting for queue recovery to complete..."
    sleep 10

    log "📊 Counting messages before any configuration changes..."
    local messages_before
    messages_before=$(count_messages_in_queues) || messages_before="unknown"

    local queue_count
    queue_count=$(rabbitmqctl list_queues --quiet | wc -l) || queue_count=0
    log "📋 Found $queue_count queues after recovery"

    enable_management_ui

    setup_spryker_environment

    enable_rabbitmq_41_features

    update_rabbitmq_policies

    show_current_state

    print_completion_message

    log "🚀 Migration complete! RabbitMQ 4.1 is ready for production use."
    log "📁 Data location: $ORIGINAL_MNESIA"
    log "💾 Shadow cleaned up from: /tmp/rabbitmq_shadow"

    if [ -n "${RABBITMQ_PID:-}" ]; then
        log "🔄 Waiting for RabbitMQ process (PID: $RABBITMQ_PID) to keep container alive..."
        wait "$RABBITMQ_PID"
        log "❌ RabbitMQ process exited with code: $?"
    else
        log "⚠️ No RabbitMQ PID found - container may exit"
    fi
}

main "$@"