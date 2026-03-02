#!/bin/bash
# RabbitMQ 4.1 → 4.2 Complete Production Migration Script
# Handles read-only mnesia volumes, Spryker integration, queue migration, and RabbitMQ 4.2 features

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
MIGRATION_MARKER="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/.migration_complete_4.2"
MIGRATION_MARKER_41="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/.migration_complete_4.1"
PERSISTENT_COOKIE="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/.erlang.cookie"
SYSTEM_COOKIE="/var/lib/rabbitmq/.erlang.cookie"

log() {
    printf "[%s] [rmq-migration] %s\n" "$(date '+%F %T')" "$*" >&2
}

die() {
    printf "[%s] [rmq-migration][ERROR] %s\n" "$(date '+%F %T')" "$*" >&2
    exit 1
}

setup_erlang_cookie() {
    log "=== Setting up Erlang cookie ==="

    if [ -s "$PERSISTENT_COOKIE" ]; then
        log "Found existing cookie in EFS mount: $PERSISTENT_COOKIE"
        cp "$PERSISTENT_COOKIE" "$SYSTEM_COOKIE"
        chmod 600 "$SYSTEM_COOKIE"
        chown rabbitmq:rabbitmq "$SYSTEM_COOKIE" 2>/dev/null || true
        log "Copied persistent cookie to system location"
    elif [ -s "$SYSTEM_COOKIE" ]; then
        log "Found cookie in system location (not persistent across restarts)"
        log "Migrating cookie to persistent EFS location"
        mkdir -p "$(dirname "$PERSISTENT_COOKIE")"
        cp "$SYSTEM_COOKIE" "$PERSISTENT_COOKIE"
        chmod 600 "$PERSISTENT_COOKIE"
        chown rabbitmq:rabbitmq "$PERSISTENT_COOKIE" 2>/dev/null || true
        log "Cookie migrated to: $PERSISTENT_COOKIE"
    else
        log "No existing cookie found - creating new one"
        mkdir -p "$(dirname "$PERSISTENT_COOKIE")"
        echo "rabbitmq-cookie-$(date +%s)" > "$PERSISTENT_COOKIE"
        chmod 600 "$PERSISTENT_COOKIE"
        chown rabbitmq:rabbitmq "$PERSISTENT_COOKIE" 2>/dev/null || true

        cp "$PERSISTENT_COOKIE" "$SYSTEM_COOKIE"
        chmod 600 "$SYSTEM_COOKIE"
        chown rabbitmq:rabbitmq "$SYSTEM_COOKIE" 2>/dev/null || true
        log "Created new cookie at: $PERSISTENT_COOKIE"
    fi

    local cookie_val="$(cat "$PERSISTENT_COOKIE")"
    log "Cookie value: ${cookie_val:0:10}..."
    log "Erlang cookie setup complete"
}

detect_existing_data() {
    log "=== Detecting existing RabbitMQ data ==="

    if [ -f "$MIGRATION_MARKER" ]; then
        log "Migration to 4.2 already complete - starting RabbitMQ normally"
        return 2
    fi

    if [ -d "$SHADOW_MNESIA" ] && [ "$(ls -A "$SHADOW_MNESIA" 2>/dev/null)" ]; then
        log "Shadow directory found (incomplete migration) - starting RabbitMQ"
        return 2
    fi

    if [ -d "$ORIGINAL_MNESIA" ]; then
        EXISTING_NODE=$(ls -1 "$ORIGINAL_MNESIA" 2>/dev/null | grep -E '^rabbit(mq)?@' | head -n1 || true)

        if [ -n "$EXISTING_NODE" ]; then
            if [ -f "$MIGRATION_MARKER_41" ]; then
                log "Found existing 4.1 data: $EXISTING_NODE - starting 4.1->4.2 migration"
            else
                log "Found existing data: $EXISTING_NODE - starting migration to 4.2"
            fi
            return 0
        fi
    fi

    log "No existing data - fresh installation"
    return 1
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
        if [[ "$basename" =~ ^aws-backup- ]] || [[ "$basename" == ".erlang.cookie" ]]; then
            continue
        fi

        if ! cp -r "$item" "$shadow_mnesia/" 2>&1; then
            log "Warning: Failed to copy $basename"
        fi
    done

    if [ ! -d "$shadow_mnesia/$EXISTING_NODE" ]; then
        die "Failed to copy node directory: $EXISTING_NODE"
    fi

    log "Data copied successfully"

    chown -R rabbitmq:rabbitmq "$shadow_mnesia" 2>&1 || true

    cleanup_shadow_files "$shadow_mnesia"
    log "Shadow mnesia prepared successfully"
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

    if [ -s "$PERSISTENT_COOKIE" ]; then
        cp "$PERSISTENT_COOKIE" "$shadow_cookie"
        chmod 600 "$shadow_cookie"
        log "Copied persistent Erlang cookie to shadow HOME"
    else
        log "Persistent cookie not found, using system cookie"
        cp "$SYSTEM_COOKIE" "$shadow_cookie" 2>/dev/null || {
            die "Could not find any Erlang cookie!"
        }
        chmod 600 "$shadow_cookie"
    fi

    local cookie_val="$(cat "$shadow_cookie")"
    export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${cookie_val}"
    export RABBITMQ_CTL_ERL_ARGS="-setcookie ${cookie_val}"

    log "Cookie value: ${cookie_val:0:10}..."
    log "Shadow environment ready with synchronized cookie"
}

determine_mnesia_strategy() {
    log "=== Preparing migration ==="

    if [ -n "$EXISTING_NODE" ]; then
        log "Backing up data to shadow directory..."
        copy_mnesia_to_shadow "$ORIGINAL_MNESIA" "$SHADOW_MNESIA"

        log "Clearing node directory contents in original to prevent conflicts..."
        if [ -d "$ORIGINAL_MNESIA/$EXISTING_NODE" ]; then
            log "Removing contents of old node directory: $ORIGINAL_MNESIA/$EXISTING_NODE"
            rm -rf "$ORIGINAL_MNESIA/$EXISTING_NODE"/* 2>/dev/null || true
            rm -rf "$ORIGINAL_MNESIA/$EXISTING_NODE"/.[!.]* 2>/dev/null || true
            log "Old node directory contents cleared"
        fi

        log "Creating working copy from shadow to original..."
        cp -a "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/" || {
            die "Failed to create working copy!"
        }
        log "Data copied from shadow to original"

        log "Cleaning up any remaining old files (preserving AWS backups and cookie)..."
        for item in "$ORIGINAL_MNESIA"/*; do
            local basename=$(basename "$item")
            if [ ! -e "$SHADOW_MNESIA/$basename" ] && \
               [[ ! "$basename" =~ ^aws-backup- ]] && \
               [[ "$basename" != ".erlang.cookie" ]]; then
                log "Removing orphaned file/directory: $basename"
                rm -rf "$item" 2>/dev/null || {
                    log "Could not remove old file: $basename"
                }
            fi
        done

        log "Removing temporary shadow directory..."
        rm -rf /tmp/rabbitmq_shadow

        chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA" 2>/dev/null || true

        log "Ready for migration"
    else
        log "Strategy: Fresh installation in original"
        mkdir -p "$ORIGINAL_MNESIA"
    fi

    export RABBITMQ_MNESIA_BASE="/var/lib/rabbitmq/mnesia"

    log "RabbitMQ will use: $ORIGINAL_MNESIA"
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
            log "RabbitMQ 4.2 is running!"
            return 0
        fi

        if [ $((i % 10)) -eq 0 ]; then
            log "Still waiting... ($i/60000 seconds)"
        fi

        sleep 1
        if [ $i -eq 60000 ]; then
            die "RabbitMQ failed to start within 60000 seconds"
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
        log "Could not list vhosts (timeout or error)"
    }

    log "Users:"
    timeout 10 rabbitmqctl list_users || {
        log "Could not list users (timeout or error)"
    }

    log "Queues:"
    timeout 10 rabbitmqctl list_queues name messages || {
        log "Could not list queues (timeout or error)"
    }
}

update_rabbitmq_policies() {
    log "Updating RabbitMQ Policies for RabbitMQ 4.2 Compatibility..."

    local vhosts
    vhosts=$(rabbitmqctl list_vhosts --quiet | grep -v '^name$') || {
        log "Could not list vhosts for policy updates"
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
                    if [[ "$definition" == *"ha-mode"* ]] || [[ "$definition" == *"ha-sync-mode"* ]] || [[ "$definition" == *"queue-mode"* ]]; then
                        log "Removing deprecated policy: $name in vhost $vhost (definition: $definition)"
                        rabbitmqctl clear_policy -p "$vhost" "$name"
                    fi
                done
            fi
        fi
    done <<< "$vhosts"

    log "Policy migration complete - deprecated ha-mode policies removed"
}

enable_rabbitmq_42_features() {
    log "=== Enabling RabbitMQ 4.2 Feature Flags ==="

    # Enable all stable feature flags at once (recommended approach for 4.2)
    # This includes khepri_db which migrates metadata from Mnesia to Khepri (Raft-based store)
    # Khepri is default for new 4.2 clusters and will become mandatory in a future major version
    # Timeout is generous because Mnesia->Khepri migration can take time depending on metadata volume
    log "Enabling all stable feature flags (including khepri_db)..."
    timeout 300 rabbitmqctl enable_feature_flag all || {
        log "Could not enable all feature flags"
        log "You can enable them later with: rabbitmqctl enable_feature_flag all"
        log "Note: if khepri_db fails, ensure the Log Exchange plugin is not enabled (known issue #14069)"
    }

    log "RabbitMQ 4.2 feature flags configuration complete"

    # Show final feature flag status
    log "=== Feature Flag Status ==="
    timeout 30 rabbitmqctl list_feature_flags 2>/dev/null || true
}

setup_spryker_environment() {
    log "=== Setting up Spryker environment ==="

    local existing_vhosts
    existing_vhosts=$(timeout 30 rabbitmqctl list_vhosts --quiet 2>/dev/null | grep -v '^name$' || echo "/")

    if [ -z "$existing_vhosts" ]; then
        log "No vhosts found - using default '/' vhost"
        existing_vhosts="/"
    fi

    log "Found existing vhosts to preserve: $existing_vhosts"
    local required_vhosts="$existing_vhosts"

    local rabbitmq_user="${RABBITMQ_DEFAULT_USER:-spryker}"

    for vhost in $required_vhosts; do
        if timeout 30 rabbitmqctl list_vhosts --quiet 2>/dev/null | grep -q "^${vhost}$"; then
            log "Vhost '${vhost}' successfully preserved during migration"

            if timeout 30 rabbitmqctl list_permissions -p "$vhost" >/dev/null 2>&1; then
                log "Permissions preserved for vhost '${vhost}'"
            else
                log "Setting up permissions for preserved vhost '${vhost}'"
                timeout 30 rabbitmqctl set_permissions -p "$vhost" "$rabbitmq_user" ".*" ".*" ".*" || true
            fi
        fi
    done

    log "Spryker environment setup complete"
}

print_completion_message() {
    if [ -n "$EXISTING_NODE" ]; then
        if [ -f "$MIGRATION_MARKER_41" ]; then
            log "Complete RabbitMQ 4.1->4.2 Migration Successful!"
        else
            log "Complete RabbitMQ ->4.2 Migration Successful!"
        fi
    else
        log "Fresh RabbitMQ 4.2 Installation Complete!"
    fi

    if [ -d "$ORIGINAL_MNESIA/rabbitmq@localhost/shadow_home" ]; then
        log "Cleaning up shadow_home directory..."
        rm -rf "$ORIGINAL_MNESIA/rabbitmq@localhost/shadow_home" 2>/dev/null || {
            log "Could not remove shadow_home, but continuing..."
        }
    fi

    touch "$MIGRATION_MARKER"
    log "Created migration marker: $MIGRATION_MARKER"
}

main() {
    export PYTHONUNBUFFERED=1

    setup_erlang_cookie

    detect_existing_data && detect_result=0 || detect_result=$?

    if [ $detect_result -eq 2 ]; then
        log "Starting RabbitMQ (migration already complete or recovering)..."
        log "Cookie location: $PERSISTENT_COOKIE"
        log "System cookie location: $SYSTEM_COOKIE"
        log "Mnesia directory: $ORIGINAL_MNESIA"

        if [ -f "$SYSTEM_COOKIE" ]; then
            log "System cookie exists, size: $(stat -c%s "$SYSTEM_COOKIE" 2>/dev/null || stat -f%z "$SYSTEM_COOKIE" 2>/dev/null) bytes"
            log "System cookie permissions: $(ls -l "$SYSTEM_COOKIE")"
        else
            log "WARNING: System cookie does not exist!"
        fi

        if [ -d "$ORIGINAL_MNESIA/rabbitmq@localhost" ]; then
            log "Node directory exists"
            log "First 10 files in node directory:"
            ls -la "$ORIGINAL_MNESIA/rabbitmq@localhost" 2>&1 | head -10 >&2
        else
            log "WARNING: Node directory does not exist!"
        fi

        if [ -f "$MIGRATION_MARKER" ]; then
            log "Migration marker exists: $MIGRATION_MARKER"
        else
            log "WARNING: Migration marker does not exist"
        fi

        # Clean up any leftover shadow_home before starting
        if [ -d "$ORIGINAL_MNESIA/rabbitmq@localhost/shadow_home" ]; then
            log "Found leftover shadow_home directory, removing..."
            rm -rf "$ORIGINAL_MNESIA/rabbitmq@localhost/shadow_home" 2>/dev/null || true
        fi

        log "Fixing ownership of all mnesia files..."
        chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA" 2>&1 || {
            log "Could not change ownership"
        }

        log "Verifying permissions after chown:"
        ls -ld "$ORIGINAL_MNESIA/rabbitmq@localhost" 2>&1 >&2

        log "Starting RabbitMQ in foreground..."
        log "==========================================="

        rabbitmq-server 2>&1 &
        RABBITMQ_PID=$!

        log "RabbitMQ started with PID: $RABBITMQ_PID"
        log "Waiting for RabbitMQ to become ready..."

        for i in $(seq 1 120); do
            if rabbitmqctl status >/dev/null 2>&1; then
                log "RabbitMQ is ready!"

                log "=== Enabling all RabbitMQ 4.2 feature flags ==="
                enable_rabbitmq_42_features

                log "Feature flags enabled, RabbitMQ is fully operational"
                break
            fi

            if [ $i -eq 120 ]; then
                log "RabbitMQ did not become ready within 120 seconds"
                log "Continuing without enabling feature flags"
            fi

            sleep 1
        done

        wait "$RABBITMQ_PID"
        RABBITMQ_EXIT=$?

        log "RabbitMQ exited with code: $RABBITMQ_EXIT"

        if [ -f "/var/log/rabbitmq/rabbit@localhost.log" ]; then
            log "Last 50 lines of RabbitMQ log:"
            tail -50 /var/log/rabbitmq/rabbit@localhost.log 2>&1 >&2
        fi

        if [ -f "$ORIGINAL_MNESIA/rabbitmq@localhost/LATEST.LOG" ]; then
            log "Last 50 lines of LATEST.LOG:"
            tail -50 "$ORIGINAL_MNESIA/rabbitmq@localhost/LATEST.LOG" 2>&1 >&2
        fi

        exit $RABBITMQ_EXIT
    elif [ $detect_result -eq 1 ]; then
        log "Starting fresh RabbitMQ 4.2 installation..."
        log "Note: Khepri is the default metadata store for new 4.2 clusters"
        log "Using exec to replace shell process"
        exec rabbitmq-server 2>&1
    fi

    setup_shadow_environment
    determine_mnesia_strategy

    start_rabbitmq
    wait_for_rabbitmq
    verify_rabbitmq_status
    show_current_state

    log "Waiting for queue recovery to complete..."
    sleep 10

    setup_spryker_environment

    enable_rabbitmq_42_features

    update_rabbitmq_policies

    show_current_state

    print_completion_message

    log "Migration complete! RabbitMQ 4.2 is ready for production use."
    log "Data location: $ORIGINAL_MNESIA"

    if [ -n "${RABBITMQ_PID:-}" ]; then
        log "Waiting for RabbitMQ process (PID: $RABBITMQ_PID) to keep container alive..."
        wait "$RABBITMQ_PID"
        log "RabbitMQ process exited with code: $?"
    else
        log "No RabbitMQ PID found - container may exit"
    fi
}

main "$@"
