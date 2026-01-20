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

copy_mnesia_to_shadow() {
    log "=== Implementing copy-on-write strategy ==="
    mkdir -p "$SHADOW_MNESIA"
    log "Copying data to shadow directory..."
    cp -a "$ORIGINAL_MNESIA"/* "$SHADOW_MNESIA/"
    chown -R rabbitmq:rabbitmq "$SHADOW_BASE"
}

determine_mnesia_strategy() {
    log "=== Preparing migration strategy ==="
    EXISTING_NODE=$(ls -1 "$ORIGINAL_MNESIA" 2>/dev/null | grep -E '^rabbit(mq)?@' | head -n1 || true)

    if [ -n "$EXISTING_NODE" ]; then
        copy_mnesia_to_shadow
        log "Clearing original EFS contents (Resource-busy safe)..."
        sync && sleep 2
        if [ -d "$ORIGINAL_MNESIA/$EXISTING_NODE" ]; then
            find "$ORIGINAL_MNESIA/$EXISTING_NODE" -mindepth 1 -delete || rm -rf "$ORIGINAL_MNESIA/$EXISTING_NODE"/*
        fi
        log "Restoring data to EFS..."
        cp -RL "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/"
        rm -rf "$SHADOW_BASE"
        chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA"
    fi
    export RABBITMQ_MNESIA_BASE="/var/lib/rabbitmq/mnesia"
}

setup_shadow_environment() {
    log "=== Setting up environment ==="
    export HOME="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/shadow_home"
    mkdir -p "$HOME"
    [ -s "/var/lib/rabbitmq/.erlang.cookie" ] && cp "/var/lib/rabbitmq/.erlang.cookie" "$HOME/.erlang.cookie"
    chmod 600 "$HOME/.erlang.cookie" || true
    chown -R rabbitmq:rabbitmq "$HOME"
    local cookie_val="$(cat "$HOME/.erlang.cookie")"
    export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${cookie_val}"
    export RABBITMQ_CTL_ERL_ARGS="-setcookie ${cookie_val}"
}

update_rabbitmq_policies() {
    log "Updating Policies (Cleaning ha-mode for 4.1 compatibility)..."
    local vhosts
    vhosts=$(su -s /bin/bash rabbitmq -c "rabbitmqctl list_vhosts --quiet") || return 1
    while IFS= read -r vhost; do
        [ -z "$vhost" ] && continue
        local policies
        policies=$(su -s /bin/bash rabbitmq -c "rabbitmqctl list_policies -p '$vhost' --quiet" 2>/dev/null) || continue
        echo "$policies" | while IFS=$'\t' read -r v_name p_name pattern apply_to definition priority; do
            if [[ "$definition" == *"ha-mode"* ]] || [[ "$definition" == *"ha-sync-mode"* ]]; then
                su -s /bin/bash rabbitmq -c "rabbitmqctl clear_policy -p '$vhost' '$p_name'"
                log "Removed deprecated ha-policy: $p_name from vhost: $vhost"
            fi
        done
    done <<< "$vhosts"
}

enable_rabbitmq_41_features() {
    log "=== Enabling RabbitMQ 4.1 Feature Flags ==="
    su -s /bin/bash rabbitmq -c "rabbitmqctl enable_feature_flag all" || {
        log "⚠️ 'enable all' failed, trying individual stable flags..."
        local flags=("quorum_queue" "stream_queue" "user_limits" "maintenance_mode_status")
        for f in "${flags[@]}"; do
            su -s /bin/bash rabbitmq -c "rabbitmqctl enable_feature_flag $f" || true
        done
    }
}

setup_spryker_environment() {
    log "=== Setting up Spryker vhost permissions ==="
    local rmq_user="${RABBITMQ_DEFAULT_USER:-spryker}"
    local vhosts
    vhosts=$(su -s /bin/bash rabbitmq -c "rabbitmqctl list_vhosts --quiet" 2>/dev/null || echo "/")
    for vhost in $vhosts; do
        log "Verifying permissions for user $rmq_user in vhost: $vhost"
        su -s /bin/bash rabbitmq -c "rabbitmqctl set_permissions -p '$vhost' '$rmq_user' '.*' '.*' '.*'" || true
    done
}

start_rabbitmq() {
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

    if [ -f "$MARKER" ]; then
        # PATH 1: Already migrated
        log "✅ Marker found - Fast-path boot"
        setup_shadow_environment
        start_rabbitmq
        ( sleep 30; su -s /bin/bash rabbitmq -c "rabbitmqctl wait --pid 1 && rabbitmqctl enable_feature_flag all" ) &
    elif [ -d "$ORIGINAL_MNESIA" ] && ls -1 "$ORIGINAL_MNESIA" 2>/dev/null | grep -qE '^rabbit(mq)?@'; then

        # PATH 2: Migration Required
        log "✅ Old data found - Starting full migration process"
        setup_shadow_environment
        determine_mnesia_strategy
        start_rabbitmq
        
        log "Waiting for RabbitMQ to stabilize..."
        for i in $(seq 1 600); do
            if su -s /bin/bash rabbitmq -c "rabbitmqctl status" >/dev/null 2>&1; then break; fi
            sleep 1
        done

        su -s /bin/bash rabbitmq -c "rabbitmq-plugins enable rabbitmq_management" || true
        enable_rabbitmq_41_features
        update_rabbitmq_policies
        setup_spryker_environment
        
        touch "$MARKER" && chown rabbitmq:rabbitmq "$MARKER"
        log "✅ Migration Successful!"
    else
        # PATH 3: Fresh Install
        log "No existing data - Fresh installation"
        setup_shadow_environment
        start_rabbitmq
    fi

    [ -n "${RABBITMQ_PID:-}" ] && wait "$RABBITMQ_PID"
}

main "$@"