#!/bin/bash
# RabbitMQ 3.13 → 4.1 Complete Production Migration Script
# Optimized for EFS persistence, Graceful Shutdown, EFS file ownership

set -euo pipefail

set -m

# Function to handle SIGTERM
terminate() {
    log "Caught SIGTERM, forwarding to children..."
    su -s /bin/bash rabbitmq -c "rabbitmqctl stop"
    log "Waiting for child processes to terminate..."
    wait
    log "All processes terminated, exiting with code 0"
    exit 0
}

trap 'terminate' SIGTERM

# Global variables
ORIGINAL_MNESIA="/var/lib/rabbitmq/mnesia"
SHADOW_BASE="/tmp/rabbitmq_shadow"
SHADOW_MNESIA="$SHADOW_BASE/mnesia"
EXISTING_NODE=""
RABBITMQ_PID=""
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

    if [ -f "$MARKER" ]; then
        log "✅ Migration marker found - skipping migration"
        ( sleep 30; su -s /bin/bash rabbitmq -c "rabbitmqctl wait --pid 1 && rabbitmqctl enable_feature_flag all" ) &
        return 1
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
    
    log "Copying mnesia data to shadow directory..."
    cp -a "$ORIGINAL_MNESIA"/* "$SHADOW_MNESIA/"
    
    chown -R rabbitmq:rabbitmq "$SHADOW_BASE"
    log "✅ Data copied and ownership set to rabbitmq"
}

setup_shadow_environment() {
    log "=== Setting up environment ==="
    export HOME="/var/lib/rabbitmq/mnesia/rabbitmq@localhost/shadow_home"
    mkdir -p "$HOME"

    local shadow_cookie="$HOME/.erlang.cookie"
    local main_cookie="/var/lib/rabbitmq/.erlang.cookie"

    if [ -s "$main_cookie" ]; then
        cp "$main_cookie" "$shadow_cookie"
    elif [ -s "$shadow_cookie" ]; then
        log "Using existing shadow Erlang cookie"
    else
        echo "rabbitmq-cookie-$(date +%s)" > "$shadow_cookie"
    fi

    chmod 600 "$shadow_cookie"
    chown -R rabbitmq:rabbitmq "$HOME"
    
    local cookie_val="$(cat "$shadow_cookie")"
    export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${cookie_val}"
    export RABBITMQ_CTL_ERL_ARGS="-setcookie ${cookie_val}"
}

determine_mnesia_strategy() {
    log "=== Preparing migration strategy ==="

    if [ -n "$EXISTING_NODE" ]; then
        copy_mnesia_to_shadow
        
        log "Clearing original EFS directory..."
        rm -rf "$ORIGINAL_MNESIA/"*

        log "Restoring data to EFS..."
        cp -a "$SHADOW_MNESIA/." "$ORIGINAL_MNESIA/"
        rm -rf "$SHADOW_BASE"

        chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA"
        log "✅ EFS cleaned and data restored with correct ownership"
    else
        mkdir -p "$ORIGINAL_MNESIA"
        chown -R rabbitmq:rabbitmq "$ORIGINAL_MNESIA"
    fi
    export RABBITMQ_MNESIA_BASE="/var/lib/rabbitmq/mnesia"
}

start_rabbitmq() {
    log "Starting RabbitMQ server as rabbitmq user..."
    su -s /bin/bash rabbitmq -c "rabbitmq-server" &
    RABBITMQ_PID=$!
}

main() {
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
        
        log "Waiting for RabbitMQ to stabilize..."
        for i in $(seq 1 600); do
            if su -s /bin/bash rabbitmq -c "rabbitmqctl status" >/dev/null 2>&1; then
                log "✅ RabbitMQ 4.1 is up!"
                break
            fi
            sleep 1
        done

        su -s /bin/bash rabbitmq -c "rabbitmq-plugins enable rabbitmq_management" || true
        su -s /bin/bash rabbitmq -c "rabbitmqctl enable_feature_flag all" || true
        
        touch "$MARKER"
        chown rabbitmq:rabbitmq "$MARKER"
        log "✅ Migration Successful!"
    fi

    if [ -n "${RABBITMQ_PID:-}" ]; then
        wait "$RABBITMQ_PID"
    fi
}

main "$@"