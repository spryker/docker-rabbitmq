#!/bin/bash
set -e
# Place file with newrelic license key
cat > /etc/newrelic-infra.yml <<EOF
---
# New Relic config file
license_key: ${NRIA_LICENSE_KEY}
EOF
# Place file with rabbitmq config
cat > /etc/newrelic-infra/integrations.d/rabbitmq-config.yml <<EOF
integrations:
- name: nri-rabbitmq
  env:
    CA_BUNDLE_DIR: /etc/ssl/certs
    EXCHANGES_REGEXES: '${RABBITMQ_EXCHANGE_REGEXES}'
    HOSTNAME: ${RABBITMQ_ENDPOINT}
    PASSWORD: ${RABBITMQ_PASSWORD}
    PORT: ${RABBITMQ_PORT}
    QUEUES_REGEXES: '${RABBITMQ_QUEUES_REGEXES}'
    VHOSTS_REGEXES: '${RABBITMQ_VHOSTS_REGEXES}'
    USE_SSL: ${RABBITMQ_USE_SSL:-false}
    USERNAME: ${RABBITMQ_USERNAME}
  interval: ${RABBITMQ_INTEGRATIONS_INTERVAL:-30}s
  labels:
    env: production
    role: rabbitmq
  inventory_source: config/rabbitmq
  
EOF
exec "$@"
