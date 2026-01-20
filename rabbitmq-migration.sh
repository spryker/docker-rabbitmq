#!/bin/bash
# RabbitMQ 3.13 → 4.1 Complete Production Migration Script
# Optimized for EFS persistence, Graceful Shutdown, 4.1 migration marker

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

# Global variables
ORIGINAL_MNESIA="/var/lib/rabbitmq/mnesia"
SHADOW_BASE="/tmp/rabbitmq_shadow"
SHADOW_MNESIA="$SHADOW_BASE/mnesia"
EXISTING_NODE=""
RABBITMQ_PID=""
# Marker to prevent redundant migration on restarts
MARKER="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/.migration_complete_4.1"

log() {
    printf "[%s] [rmq-migration] %s\n" "$(date '+%F %T')" "$*" >&2
}

die() {
    printf "[%s] [rmq-migration][ERROR] %s\n" "$(date '+%F %T')" "$*" >&2
    exit 1
}

detect_existing_data() {
    log "=== Detecting existing RabbitMQ data ==="

    # 1. Check for the 4.1 Migration Marker
    if [ -f "$MARKER" ]; then
        log "✅ Migration marker found - skipping migration and starting RabbitMQ 4.1"
        ( sleep 30; rabbitmqctl wait --pid 1 && rabbitmqctl enable_feature_flag all ) &
        return 1
    fi

    # 2. Check for leftover shadow data in /tmp
    if [ -d "$SHADOW_MNESIA" ] && [ "$(ls -A "$SHADOW_MNESIA" 2>/dev/null)" ]; then
        log "✅ Shadow data detected in /tmp, resuming migration..."
        return 0
    fi

    # 3. Check for original 3.13 data on EFS
    if [ -d "$ORIGINAL_MNESIA" ]; then
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
        log "✅ Original mnesia is writable"
        return 0
    else
        log "⚠️ Original mnesia is read-only - copy-on-write required"
        return 1
    fi
}

copy_mnesia_to_shadow() {
    local source_mnesia="$1"
    local shadow_mnesia="$2"

    log "=== Implementing copy-on-write strategy ==="
    log "Source: $source_mnesia"
    log "Target: $shadow_mnesia"

    mkdir -p "$shadow_mnesia" || die "Failed to create shadow directory"

    log "Copying mnesia data to shadow directory..."

    for item in "$source_mnesia"/*; do
        local basename=$(basename "$item")
        if [[ "$basename" =~ ^aws-backup- ]]; then
            continue
        fi

        if ! cp -a "$item" "$shadow_mnesia/" 2>&1; then
            log "⚠️ Warning: Failed to copy $basename"
        fi
    done

    if [ ! -d "$shadow_mnesia/$EXISTING_NODE" ]; then
        die "❌ Failed to copy node directory: $EXISTING_NODE"
    fi

    log "✅ Data copied successfully to /tmp"
    chown -R rabbitmq:rabbitmq "$shadow_mnesia" 2>&1 || true
    cleanup_shadow_files "$shadow_mnesia"
}

cleanup_shadow_files() {
    local shadow_mnesia="$1"
    find "$shadow_mnesia" -name "*.pid" -delete 2>/dev/null || true
    find "$shadow_mnesia" -name "*.lock" -delete 2>/dev/null || true
    log "✅ Shadow mnesia cleaned and prepared"
}

setup_shadow_environment() {
    log "=== Setting up environment ==="

    export HOME="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/shadow_home"
    mkdir -p "$HOME"

    local shadow_cookie="$HOME/.erlang.cookie"
    local main_cookie="/var/lib/rabbitmq/.erlang.cookie"

    if [ -s "$main_cookie" ] && [ -r "$main_cookie" ]; then
        cp "$main_cookie" "$shadow_cookie"
        log "Copied existing Erlang cookie to shadow_home"
    elif [ -s "$shadow_cookie" ]; then
        log "Using existing persistent Erlang cookie from EFS"
    else
        echo "rabbitmq-cookie-$(date +%s)" > "$shadow_cookie"
        log "Created new Erlang cookie in shadow_home"
    fi

    chmod 600 "$shadow_cookie"
    local cookie_val="$(cat "$shadow_cookie")"
    export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${cookie_val}"
    export RABBITMQ_CTL_ERL_ARGS="-setcookie ${cookie_val}"
    chown -R rabbitmq:rabbitmq "$HOME" 2>/dev/null || true

    log "✅ Environment ready with persistent cookie"
}

determine_mnesia_strategy() {
    log "=== Preparing migration strategy ==="

    if [ -n "$EXISTING_NODE" ]; then
        log "Backing up data to shadow directory..."
        copy_mnesia_to_shadow "$ORIGINAL_MNESIA" "$SHADOW_MNESIA"

        log "Clearing original EFS directory..."
        rm -rf "$ORIGINAL_MNESIA/"*

        log "Restoring data to EFS and cleaning up /tmp..."
        cp -a "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/"
        rm -rf "$SHADOW_BASE"

        chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA" 2>/dev/null || true
        log "✅ Ready for migration"
    else
        log "Strategy: Fresh installation"
        mkdir -p "$ORIGINAL_MNESIA"
    fi

    export RABBITMQ_MNESIA_BASE="/var/lib/rabbitmq/mnesia"
}

start_rabbitmq() {
    epmd -kill >/dev/null 2>&1 || true

    log "Starting RabbitMQ server..."
    rabbitmq-server &
    RABBITMQ_PID=$!
    log "RabbitMQ started with PID: $RABBITMQ_PID"
}

wait_for_rabbitmq() {
    log "=== Waiting for RabbitMQ ready status ==="
    # High timeout for slow EFS storage
    for i in $(seq 1 60000); do
        if rabbitmqctl status >/dev/null 2>&1; then
            log "✅ RabbitMQ 4.1 is fully operational!"
            return 0
        fi
        sleep 1
    done
    die "❌ RabbitMQ failed to start"
}

verify_rabbitmq_status() {
    log "=== Verifying RabbitMQ Status ==="
    rabbitmqctl status || die "Failed to get RabbitMQ status"
}

show_current_state() {
    log "=== Current RabbitMQ State ==="
    rabbitmqctl list_vhosts || true
    rabbitmqctl list_users || true
}

enable_management_ui() {
    log "Enabling management plugin..."
    rabbitmq-plugins enable rabbitmq_management || return 1
}

update_rabbitmq_policies() {
    log "Updating Policies (Cleaning ha-mode for 4.1)..."
    local vhosts
    vhosts=$(rabbitmqctl list_vhosts --quiet) || return 1

    while IFS= read -r vhost; do
        [ -z "$vhost" ] && continue
        log "Checking policies for vhost: $vhost"
        local policies
        policies=$(rabbitmqctl list_policies -p "$vhost" --quiet 2>/dev/null) || continue
        
        echo "$policies" | while IFS=$'\t' read -r v_name p_name pattern apply_to definition priority; do
            if [[ "$definition" == *"ha-mode"* ]] || [[ "$definition" == *"ha-sync-mode"* ]]; then
                rabbitmqctl clear_policy -p "$vhost" "$p_name"
                log "Removed ha-policy: $p_name"
            fi
        done
    done <<< "$vhosts"
}

count_messages_in_queues() {
    log "=== Counting Messages ==="
    rabbitmqctl list_queues messages || true
}

enable_rabbitmq_41_features() {
    log "=== Enabling RabbitMQ 4.1 Feature Flags ==="
    rabbitmqctl enable_feature_flag all || log "⚠️ Could not enable all flags automatically"
}

setup_spryker_environment() {
    log "=== Setting up Spryker environment ==="
    local rabbitmq_user="${RABBITMQ_DEFAULT_USER:-spryker}"
    local vhosts
    vhosts=$(rabbitmqctl list_vhosts --quiet 2>/dev/null || echo "/")
    
    for vhost in $vhosts; do
        log "Verifying permissions for vhost: $vhost"
        rabbitmqctl set_permissions -p "$vhost" "$rabbitmq_user" ".*" ".*" ".*" || true
    done
}

print_completion_message() {
    if [ -n "$EXISTING_NODE" ]; then
        touch "$MARKER"
        log "✅ Complete RabbitMQ 3.13→4.1 Migration Successful!"
    else
        log "✅ Fresh RabbitMQ 4.1 Installation Complete!"
    fi
}

main() {
    # Auto-repair nested mnesia directories if they exist from previous failed attempts
    if [ -d /var/lib/rabbitmq/mnesia/mnesia ]; then
        log "Repairing nested mnesia structure..."
        cp -a /var/lib/rabbitmq/mnesia/mnesia/. /var/lib/rabbitmq/mnesia/
        rm -rf /var/lib/rabbitmq/mnesia/mnesia
    fi

    if ! detect_existing_data; then
        setup_shadow_environment
        start_rabbitmq
    else
        setup_shadow_environment
        determine_mnesia_strategy
        start_rabbitmq
        wait_for_rabbitmq
        verify_rabbitmq_status
        enable_management_ui
        setup_spryker_environment
        enable_rabbitmq_41_features
        update_rabbitmq_policies
        print_completion_message
    fi

    # Keep the script alive so the TRAP can listen for SIGTERM
    if [ -n "${RABBITMQ_PID:-}" ]; then
        log "🔄 PID 1 active. Waiting for RabbitMQ (PID: $RABBITMQ_PID)..."
        wait "$RABBITMQ_PID"
        log "❌ RabbitMQ process exited."
    else
        log "⚠️ No PID found, script exiting."
    fi
}

main "$@"