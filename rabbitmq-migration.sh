#!/bin/bash
# RabbitMQ 3.13 → 4.1 Complete Production Migration Script
# Optimized for EFS persistence, Graceful Shutdown, EFS file ownership

set -euo pipefail
set -m

terminate() {
    log "Caught SIGTERM, forwarding to children..."
    su -s /bin/bash rabbitmq -c "rabbitmqctl stop"
    log "Waiting for child processes to terminate..."
    wait
    log "All processes terminated, exiting with code 0"
    exit 0
}

trap 'terminate' SIGTERM

ORIGINAL_MNESIA="/var/lib/rabbitmq/mnesia"
SHADOW_BASE="/tmp/rabbitmq_shadow"
SHADOW_MNESIA="$SHADOW_BASE/mnesia"
EXISTING_NODE=""
RABBITMQ_PID=""
MARKER="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/.migration_complete_4.1"

log() { printf "[%s] [rmq-migration] %s\n" "$(date '+%F %T')" "$*" >&2; }
die() { printf "[%s] [rmq-migration][ERROR] %s\n" "$(date '+%F %T')" "$*" >&2; exit 1; }


detect_existing_data() {
    log "=== Detecting existing RabbitMQ data ==="

    if [ -f "$MARKER" ]; then
        log "✅ Marker found - migration already completed."
        return 2
    fi

    if [ -d "$ORIGINAL_MNESIA" ]; then
        EXISTING_NODE=$(ls -1 "$ORIGINAL_MNESIA" 2>/dev/null | grep -E '^rabbit(mq)?@' | head -n1 || true)
        if [ -n "$EXISTING_NODE" ]; then
            log "✅ Found existing 3.13 data: $EXISTING_NODE - starting migration"
            return 0
        fi
    fi

    log "No existing data - fresh installation"
    return 1
}

copy_mnesia_to_shadow() {
    log "=== Implementing copy-on-write strategy ==="
    mkdir -p "$SHADOW_MNESIA"
    log "Copying EFS data to local /tmp shadow directory..."
    cp -a "$ORIGINAL_MNESIA"/* "$SHADOW_MNESIA/"
    chown -R rabbitmq:rabbitmq "$SHADOW_BASE"
}

determine_mnesia_strategy() {
    log "=== Preparing migration strategy ==="
    if [ -n "$EXISTING_NODE" ]; then
        copy_mnesia_to_shadow

        log "Clearing original EFS contents (Resource-busy safe)..."
        sync && sleep 2
        rm -rf "$ORIGINAL_MNESIA"/*
        
        log "Restoring upgraded data to EFS..."
        cp -a "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/"
        rm -rf "$SHADOW_BASE"
        log "✅ Data restored to EFS"
    else
        mkdir -p "$ORIGINAL_MNESIA"
    fi
}

setup_shadow_environment() {
    log "=== Setting up environment ==="
    export HOME="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/shadow_home"
    mkdir -p "$HOME"
    
    local shadow_cookie="$HOME/.erlang.cookie"
    local main_cookie="/var/lib/rabbitmq/.erlang.cookie"

    if [ -s "$main_cookie" ]; then
        log "Migrating existing cookie to shadow home..."
        cp "$main_cookie" "$shadow_cookie"
    elif [ ! -s "$shadow_cookie" ]; then
        log "Generating new Erlang cookie..."
        COOKIE_VAL=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32 || true)
        echo "$COOKIE_VAL" > "$shadow_cookie"
    fi

    chmod 600 "$shadow_cookie"
    chown rabbitmq:rabbitmq "$shadow_cookie"
    chown -R rabbitmq:rabbitmq "$HOME"
    
    local final_cookie="$(cat "$shadow_cookie")"
    export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${final_cookie}"
    export RABBITMQ_CTL_ERL_ARGS="-setcookie ${final_cookie}"
}

wait_for_rabbitmq() {
    log "=== Waiting for RabbitMQ to become ready ==="
    local timeout=6000
    for i in $(seq 1 $timeout); do
        if su -s /bin/bash rabbitmq -c "rabbitmqctl check_running" >/dev/null 2>&1; then
            log "✅ RabbitMQ 4.1 is fully running!"
            return 0
        fi
        [ $((i % 10)) -eq 0 ] && log "Still waiting for startup/conversion... ($i/$timeout seconds)"
        sleep 1
    done
    die "❌ RabbitMQ failed to start within $timeout seconds"
}

update_rabbitmq_policies() {
    log "Updating Policies (Removing ha-mode for 4.1 compatibility)..."
    local vhosts
    vhosts=$(su -s /bin/bash rabbitmq -c "rabbitmqctl list_vhosts --quiet") || return 1
    while IFS= read -r vhost; do
        [ -z "$vhost" ] && continue
        local policies
        policies=$(su -s /bin/bash rabbitmq -c "rabbitmqctl list_policies -p '$vhost' --quiet" 2>/dev/null) || continue
        echo "$policies" | while IFS=$'\t' read -r vhost_name p_name pattern apply_to definition priority; do
            if [[ "$definition" == *"ha-mode"* ]] || [[ "$definition" == *"ha-sync-mode"* ]]; then
                su -s /bin/bash rabbitmq -c "rabbitmqctl clear_policy -p '$vhost' '$p_name'"
                log "Removed deprecated ha-policy: $p_name from vhost: $vhost"
            fi
        done
    done <<< "$vhosts"
}

enable_rabbitmq_41_features() {
    log "=== Enabling RabbitMQ 4.1 Feature Flags ==="
    su -s /bin/bash rabbitmq -c "rabbitmqctl enable_feature_flag all" || true
}

setup_spryker_environment() {
    log "=== Setting up Spryker environment ==="
    local rmq_user="${RABBITMQ_DEFAULT_USER:-spryker}"
    local vhosts
    vhosts=$(su -s /bin/bash rabbitmq -c "rabbitmqctl list_vhosts --quiet" 2>/dev/null || echo "/")
    for vhost in $vhosts; do
        su -s /bin/bash rabbitmq -c "rabbitmqctl set_permissions -p "$vhost" "$rmq_user" ".*" ".*" ".*"" || true
    done
}

count_messages_in_queues() {
    log "=== Counting Messages in Queues ==="
    su -s /bin/bash rabbitmq -c "rabbitmqctl list_queues name messages" || true
}

start_rabbitmq() {
    log "Ensuring EFS permissions for rabbitmq user..."
    chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA"
    
    log "Starting RabbitMQ server as rabbitmq user..."
    su -s /bin/bash rabbitmq -c "rabbitmq-server" &
    RABBITMQ_PID=$!
}

main() {
    if [ -d /var/lib/rabbitmq/mnesia/mnesia ]; then
        log "Repairing nested mnesia structure..."
        chown -R rabbitmq:rabbitmq /var/lib/rabbitmq/mnesia/mnesia 2>/dev/null || true
        cp -a /var/lib/rabbitmq/mnesia/mnesia/. /var/lib/rabbitmq/mnesia/ && rm -rf /var/lib/rabbitmq/mnesia/mnesia
    fi

    set +e
    detect_existing_data
    local status=$?
    set -e

    if [ $status -eq 2 ]; then
        log "✅ Skipping migration path."
        setup_shadow_environment
        start_rabbitmq
        ( su -s /bin/bash rabbitmq -c "rabbitmqctl wait --pid 1 --timeout 300" && su -s /bin/bash rabbitmq -c "rabbitmqctl enable_feature_flag all" ) &

    elif [ $status -eq 0 ]; then
        log "✅ Starting migration path."
        setup_shadow_environment
        determine_mnesia_strategy
        start_rabbitmq
        
        wait_for_rabbitmq
        
        log "📊 Status check before configuration..."
        count_messages_in_queues
        
        su -s /bin/bash rabbitmq -c "rabbitmq-plugins enable rabbitmq_management" || true
        enable_rabbitmq_41_features
        update_rabbitmq_policies
        setup_spryker_environment
        
        touch "$MARKER" && chown rabbitmq:rabbitmq "$MARKER"
        log "✅ Migration Successful!"

    else
        log "✅ Fresh install path."
        setup_shadow_environment
        start_rabbitmq
    fi

    [ -n "${RABBITMQ_PID:-}" ] && wait "$RABBITMQ_PID"
}

main "$@"