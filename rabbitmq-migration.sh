#!/bin/bash
# RabbitMQ 3.13 → 4.1: in-place (если есть данные) + миграция classic→quorum
# Без правок образа; обходим /var/lib/rabbitmq/.erlang.cookie через -setcookie.

set -euo pipefail

log(){ printf "%s %s\n" "[$(date '+%F %T')] [rmq-migration]" "$*" >&2; }
die(){ printf "%s %s\n" "[$(date '+%F %T')] [rmq-migration][ERROR]" "$*" >&2; exit 1; }

# --- ENV ---
RABBIT_USER="${RABBITMQ_DEFAULT_USER:-${RABBITMQ_USER:-spryker}}"
RABBIT_PASS="${RABBITMQ_DEFAULT_PASS:-${RABBITMQ_PASSWORD:-secret}}"
MGMT_HOST="${RABBITMQ_MANAGEMENT_HOST:-localhost}"
MGMT_PORT="${RABBITMQ_MANAGEMENT_PORT:-15672}"
DO_MIGRATE_QUEUES="${DO_MIGRATE_QUEUES:-1}"

MNESIA_ROOT="/var/lib/rabbitmq/mnesia"

# --- HTTP helper ---
_http(){ command -v curl >/dev/null && curl -fsS --max-time 2 "$1" || wget -qO- "$1"; }

# --- Detect existing node name (for in-place upgrade) ---
NODE_FROM_DATA=""
if [ -d "$MNESIA_ROOT" ]; then
  NODE_FROM_DATA="$(ls -1 "$MNESIA_ROOT" 2>/dev/null | grep -E '^rabbit@' | head -n1 || true)"
fi

if [ -n "$NODE_FROM_DATA" ]; then
  export RABBITMQ_NODENAME="$NODE_FROM_DATA"
  HOST_ONLY="${NODE_FROM_DATA#rabbit@}"
  grep -qE "([[:space:]]|^)$HOST_ONLY([[:space:]]|$)" /etc/hosts || echo "127.0.0.1 $HOST_ONLY" >> /etc/hosts
  log "Found existing node data: $NODE_FROM_DATA (in-place upgrade)"
else
  export RABBITMQ_NODENAME="${RABBITMQ_NODENAME:-rabbit@broker}"
  grep -qE '(^|[[:space:]])broker([[:space:]]|$)' /etc/hosts || echo "127.0.0.1 broker" >> /etc/hosts
  log "No node data found — fresh/shadow node: $RABBITMQ_NODENAME"
fi

# --- Force our own cookie and HOME (avoid /var/lib/rabbitmq/.erlang.cookie) ---
SHADOW="/tmp/rmq-shadow"
mkdir -p "$SHADOW"
export HOME="$SHADOW"

COOKIE="$HOME/.erlang.cookie"
if [ ! -s "$COOKIE" ]; then
  head -c 32 /dev/urandom | base64 | tr -d '\n' > "$COOKIE" 2>/dev/null || echo "changemechangemechangeme1234" > "$COOKIE"
fi
chmod 600 "$COOKIE" || true
COOKIE_VAL="$(cat "$COOKIE" 2>/dev/null || echo "changemechangemechangeme1234")"
export RABBITMQ_SERVER_ERL_ARGS="-setcookie ${COOKIE_VAL}"
export RABBITMQ_CTL_ERL_ARGS="-setcookie ${COOKIE_VAL}"

# Логи в stdout
export RABBITMQ_LOGS="-"
export RABBITMQ_SASL_LOGS="-"

# Если данных нет — держим mnesia в тени, чтобы не писать в /var/lib
if [ -z "$NODE_FROM_DATA" ]; then
  export RABBITMQ_MNESIA_BASE="$SHADOW/mnesia"
  mkdir -p "$RABBITMQ_MNESIA_BASE"
fi

# Иногда epmd залипает между рестартами
epmd -kill >/dev/null 2>&1 || true

# === DIAGNOSTIC INFO BEFORE START ===
log "=== PRE-START DIAGNOSTICS ==="
log "Current user: $(whoami)"
log "Current UID/GID: $(id)"
log "HOME: $HOME"
log "RABBITMQ_NODENAME: $RABBITMQ_NODENAME"
log "Cookie file: $COOKIE"
log "Cookie permissions: $(ls -la "$COOKIE" 2>/dev/null || echo 'not found')"
log "Mnesia base: ${RABBITMQ_MNESIA_BASE:-/var/lib/rabbitmq/mnesia}"
log "Mnesia permissions: $(ls -la "${RABBITMQ_MNESIA_BASE:-/var/lib/rabbitmq/mnesia}" 2>/dev/null || echo 'not found')"
log "EPMD status before start:"
epmd -names 2>/dev/null || log "EPMD not running"
log "Available disk space:"
df -h /tmp /var/lib/rabbitmq 2>/dev/null || true
log "=== END DIAGNOSTICS ==="

# Fix mnesia permissions if needed
if [ -d "$MNESIA_ROOT" ]; then
    log "Fixing mnesia permissions..."
    chown -R rabbitmq:rabbitmq "$MNESIA_ROOT" 2>/dev/null || {
        log "⚠️ Cannot fix mnesia permissions, trying to continue..."
        # If we can't fix permissions, try to use shadow directory
        export RABBITMQ_MNESIA_BASE="$SHADOW/mnesia"
        mkdir -p "$RABBITMQ_MNESIA_BASE"
        log "Using shadow mnesia directory: $RABBITMQ_MNESIA_BASE"
    }
fi

log "MGMT: ${MGMT_HOST}:${MGMT_PORT}  USER: ${RABBIT_USER}"
log "DO_MIGRATE_QUEUES=${DO_MIGRATE_QUEUES}"
log "Starting RabbitMQ (foreground for diagnostics)…"

# Start RabbitMQ in background to capture output but allow script to continue
rabbitmq-server &
RABBITMQ_PID=$!
log "RabbitMQ started with PID: $RABBITMQ_PID"

# Give it a moment to initialize
sleep 3

# Check if process is still running
if ! kill -0 $RABBITMQ_PID 2>/dev/null; then
    log "❌ RabbitMQ process died immediately after startup"
    log "Checking for error logs..."

    # Try to get some diagnostic info
    log "=== EPMD status after failed start ==="
    epmd -names || true

    log "=== Trying direct start for error output ==="
    timeout 10 rabbitmq-server || true

    die "RabbitMQ failed to start - check logs above"
fi

# --- wait core ---
log "Waiting for rabbit core…"
for i in $(seq 1 180); do
  if rabbitmqctl status >/dev/null 2>&1; then break; fi
  sleep 1
  [ $i -eq 20 ] && { log "early diagnostics (20s):"; rabbitmq-diagnostics ping || true; }
  [ $i -eq 60 ] && { log "mid diagnostics (60s):"; rabbitmq-diagnostics listeners || true; }
  [ $i -eq 120 ] && { log "late diagnostics (120s):"; epmd -names || true; }
done
rabbitmqctl status >/dev/null 2>&1 || die "RabbitMQ core did not start (check cookie/nodename)"

log "== listeners =="
rabbitmq-diagnostics listeners || true

# --- wait management ---
log "Waiting for management http (${MGMT_HOST}:${MGMT_PORT})…"
for j in $(seq 1 120); do
  _http "http://${MGMT_HOST}:${MGMT_PORT}/api/healthchecks/node" >/dev/null 2>&1 && break
  sleep 1
done
_http "http://${MGMT_HOST}:${MGMT_PORT}/api/healthchecks/node" >/dev/null 2>&1 || die "Management API not up in 120s"

# --- ensure user/vhosts/perms ---
rabbitmqctl add_user "$RABBIT_USER" "$RABBIT_PASS" 2>/dev/null || true
rabbitmqctl set_user_tags "$RABBIT_USER" administrator 2>/dev/null || true
for v in eu-docker us-docker; do
  rabbitmqctl add_vhost "$v" 2>/dev/null || true
  rabbitmqctl set_permissions -p "$v" "$RABBIT_USER" ".*" ".*" ".*" 2>/dev/null || true
done
VHOSTS="$(rabbitmqctl list_vhosts --formatter=tsv 2>/dev/null | awk 'NR>1{print $1}')"

# --- feature flags (без опасных) ---
log "Enabling feature flags…"
rabbitmqctl list_feature_flags --formatter=pretty_table || true
while read -r f _; do
  [ -z "$f" ] && continue
  case "$f" in khepri_db|classic_queue_mirroring) continue ;; esac
  rabbitmqctl enable_feature_flag "$f" >/dev/null 2>&1 || true
done <<EOF
$(rabbitmqctl list_feature_flags --formatter=tsv 2>/dev/null | awk 'NR>1{print $1" "$2}')
EOF

# --- remove ha-mode from policies + default quorum policy ---
log "Cleaning policies (remove ha-mode)…"
for v in $VHOSTS; do
  POL="$(rabbitmqctl list_policies -p "$v" name pattern apply_to priority definition --formatter=tsv 2>/dev/null || true)"
  echo "$POL" | awk 'NR>1' | while read -r name pattern apply_to priority definition; do
    DEF="$(rabbitmqctl list_policies -p "$v" name definition --formatter=tsv 2>/dev/null | awk -v n="$name" 'NR>1&&$1==n{sub($1 FS,"");print}')"
    echo "$DEF" | grep -q '"ha-mode"' || continue
    NEWDEF="$(printf "%s" "$DEF" | sed 's/"ha-mode"[[:space:]]*:[[:space:]]*"[^"]*"[,]*//g' | sed 's/"ha-sync-mode"[[:space:]]*:[[:space:]]*"[^"]*"[,]*//g' | sed 's/, *}/}/g')"
    [ -z "${apply_to:-}" ] || [ "$apply_to" = "null" ] && apply_to="queues"
    [ -z "${priority:-}" ] && priority=0
    rabbitmqctl set_policy -p "$v" "$name" "$pattern" "$NEWDEF" --priority "$priority" --apply-to "$apply_to" >/dev/null 2>&1 || true
  done
  rabbitmqctl set_policy -p "$v" LazyAndQuorum "^(?!amq\.|temporary_|temp_migration_).+" \
    '{"queue-mode":"lazy","x-queue-type":"quorum"}' --priority 0 --apply-to queues >/dev/null 2>&1 || true
done

# --- migrate queues classic → quorum (via Shovel) ---
if [ "$DO_MIGRATE_QUEUES" = "1" ]; then
  log "== START QUEUE MIGRATION =="
  if ! _http "http://${RABBIT_USER}:${RABBIT_PASS}@${MGMT_HOST}:${MGMT_PORT}/api/whoami" >/dev/null 2>&1; then
    log "SKIP: management auth failed — check RABBIT_USER/PASS."
  else
    rabbitmq-plugins enable rabbitmq_shovel rabbitmq_shovel_management >/dev/null 2>&1 || true
    for v in $VHOSTS; do
      Q="$(rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" list queues name messages arguments --format=tsv 2>/dev/null || true)"
      [ -z "$Q" ] && { log "[$v] no queues — skip"; continue; }
      echo "$Q" | awk 'NR>1' | while IFS=$'\t' read -r qname messages args; do
        case "$qname" in amq.*|temporary_*|temp_migration_*) continue ;; esac
        printf "%s" "$args" | grep -q '"x-queue-type":"quorum"' && { log "[$v] $qname already quorum — skip"; continue; }
        msgs="${messages:-0}"
        if [ "$msgs" = "0" ]; then
          log "[$v] $qname empty → recreate as quorum"
          rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" delete queue name="$qname" >/dev/null 2>&1 || true
          rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" declare queue name="$qname" durable=true arguments='{"x-queue-type":"quorum"}' >/dev/null 2>&1 || true
          continue
        fi
        TQ="temp_migration_${qname}_$(date +%s)"
        URI="amqp://${RABBIT_USER}:${RABBIT_PASS}@127.0.0.1/${v}"
        S1="shovel_to_temp_${qname}_$(date +%s)"
        S2="shovel_to_original_${qname}_$(date +%s)"

        log "[$v] create $TQ"
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" declare queue name="$TQ" durable=true >/dev/null 2>&1 || true

        log "[$v] shovel $S1 ($qname → $TQ)"
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" declare parameter component=shovel name="$S1" \
          value="{\"src-uri\":\"$URI\",\"src-queue\":\"$qname\",\"dest-uri\":\"$URI\",\"dest-queue\":\"$TQ\",\"ack-mode\":\"on-confirm\",\"delete-after\":\"queue-length\"}" >/dev/null 2>&1 || true

        # wait empty source
        for t in $(seq 1 300); do
          cur="$(rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" list queues name messages --format=tsv 2>/dev/null | awk -v q="$qname" '$1==q{print $2}')"
          [ -z "$cur" ] && cur=0
          [ "$cur" = "0" ] && { log "[$v] $qname drained"; break; }
          sleep 1
        done

        log "[$v] recreate $qname as quorum"
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" delete queue name="$qname" >/dev/null 2>&1 || true
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" declare queue name="$qname" durable=true arguments='{"x-queue-type":"quorum"}' >/dev/null 2>&1 || true

        log "[$v] shovel $S2 ($TQ → $qname)"
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" declare parameter component=shovel name="$S2" \
          value="{\"src-uri\":\"$URI\",\"src-queue\":\"$TQ\",\"dest-uri\":\"$URI\",\"dest-queue\":\"$qname\",\"ack-mode\":\"on-confirm\",\"delete-after\":\"queue-length\"}" >/dev/null 2>&1 || true

        # wait empty temp
        for t in $(seq 1 300); do
          curT="$(rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" list queues name messages --format=tsv 2>/dev/null | awk -v q="$TQ" '$1==q{print $2}')"
          [ -z "$curT" ] && curT=0
          [ "$curT" = "0" ] && { log "[$v] $TQ drained"; break; }
          sleep 1
        done

        log "[$v] cleanup temp + shovels"
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" delete queue name="$TQ" >/dev/null 2>&1 || true
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" delete parameter component=shovel name="$S1" >/dev/null 2>&1 || true
        rabbitmqadmin -u "$RABBIT_USER" -p "$RABBIT_PASS" -V "$v" delete parameter component=shovel name="$S2" >/dev/null 2>&1 || true
      done
    done
  fi
else
  log "Queue migration disabled (DO_MIGRATE_QUEUES!=1)"
fi

log "Done. Node: $RABBITMQ_NODENAME"
rabbitmqctl list_vhosts --formatter=pretty_table || true
tail -f /dev/null
