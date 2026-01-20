#!/bin/bash
# RabbitMQ 3.13 → 4.1 Complete Production Migration Script
# Optimized for EFS persistence, Graceful Shutdown, EFS file ownership

set -euo pipefail
set -m

terminate() {
    log "Caught SIGTERM, forwarding to children..."
    rabbitmqctl stop || kill -TERM "$RABBITMQ_PID"
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
        log "✅ Migration marker found - skipping migration logic"
        return 2
    fi

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

copy_mnesia_to_shadow() {
    log "=== Implementing copy-on-write strategy ==="
    mkdir -p "$SHADOW_MNESIA"
    log "Copying mnesia data to local shadow directory..."
    cp -a "$ORIGINAL_MNESIA"/* "$SHADOW_MNESIA/"
    chown -R rabbitmq:rabbitmq "$SHADOW_BASE"
}

setup_shadow_environment() {
    log "=== Setting up shadow environment ==="
    export HOME="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/shadow_home"
    mkdir -p "$HOME"

    local shadow_cookie="$HOME/.erlang.cookie"
    local main_cookie="/var/lib/rabbitmq/.erlang.cookie"

    if [ -s "$main_cookie" ]; then
        cp "$main_cookie" "$shadow_cookie"
    elif [ ! -s "$shadow_cookie" ]; then
        log "Generating new cookie..."
        tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1 > "$shadow_cookie"
    fi

    chmod 600 "$shadow_cookie"
    chown -R rabbitmq:rabbitmq "$HOME"
    
    local cookie_val="$(cat "$shadow_cookie")"
    export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${cookie_val}"
    export RABBITMQ_CTL_ERL_ARGS="-setcookie ${cookie_val}"
}

determine_mnesia_strategy() {
    log "=== Preparing migration ==="
    if [ -n "$EXISTING_NODE" ]; then
        copy_mnesia_to_shadow

        log "Clearing original EFS contents (Resource-busy safe)..."
        sync && sleep 2
        rm -rf "$ORIGINAL_MNESIA/"*

        log "Restoring data to EFS..."
        cp -a "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/"
        rm -rf "$SHADOW_BASE"

        log "✅ Data restored to EFS"
    else
        mkdir -p "$ORIGINAL_MNESIA"
    fi
}

start_rabbitmq() {
    log "Ensuring EFS permissions for rabbitmq user..."
    chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA"
    
    log "Starting RabbitMQ server..."
    rabbitmq-server &
    RABBITMQ_PID=$!
}

wait_for_rabbitmq() {
    log "=== Waiting for RabbitMQ to become ready ==="
    for i in $(seq 1 6000); do
        if rabbitmqctl check_running >/dev/null 2>&1; then
            log "✅ RabbitMQ 4.1 is running!"
            return 0
        fi
        [ $((i % 10)) -eq 0 ] && log "Still waiting... ($i/600 seconds)"
        sleep 1
    done
    die "❌ RabbitMQ failed to start"
}

enable_management_ui() {
    rabbitmq-plugins enable rabbitmq_management
}

enable_rabbitmq_41_features() {
    rabbitmqctl enable_feature_flag all || true
}

update_rabbitmq_policies() {
    log "Updating Policies (Cleaning ha-mode)..."
    local vhosts
    vhosts=$(rabbitmqctl list_vhosts --quiet) || return 1
    while IFS= read -r vhost; do
        [ -z "$vhost" ] && continue
        local policies
        policies=$(rabbitmqctl list_policies -p "$vhost" --quiet 2>/dev/null) || continue
        echo "$policies" | while IFS=$'\t' read -r v_vhost v_name v_pattern v_apply v_def v_prio; do
            if [[ "$v_def" == *"ha-mode"* ]]; then
                rabbitmqctl clear_policy -p "$vhost" "$v_name"
            fi
        done
    done <<< "$vhosts"
}


main() {
    if [ -d /var/lib/rabbitmq/mnesia/mnesia ]; then
        log "Repairing nested mnesia structure..."
        cp -a /var/lib/rabbitmq/mnesia/mnesia/. /var/lib/rabbitmq/mnesia/
        rm -rf /var/lib/rabbitmq/mnesia/mnesia
    fi

    set +e
    detect_existing_data
    local status=$?
    set -e

    if [ $status -eq 2 ]; then
        # SKIP PATH
        setup_shadow_environment
        start_rabbitmq
        ( sleep 30; rabbitmqctl wait --pid 1 && rabbitmqctl enable_feature_flag all ) &
    elif [ $status -eq 0 ]; then
        # MIGRATION PATH
        setup_shadow_environment
        determine_mnesia_strategy
        start_rabbitmq
        wait_for_rabbitmq
        
        # Post-migration config
        enable_management_ui
        enable_rabbitmq_41_features
        update_rabbitmq_policies
        
        # CREATE MARKER
        touch "$MARKER"
        chown rabbitmq:rabbitmq "$MARKER"
        log "✅ Migration complete!"
    else
        # FRESH INSTALL
        setup_shadow_environment
        start_rabbitmq
    fi

    if [ -n "${RABBITMQ_PID:-}" ]; then
        wait "$RABBITMQ_PID"
    fi
}

main "$@"