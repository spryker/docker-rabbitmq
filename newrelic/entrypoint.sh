#!/bin/bash
set -e
# Place file with newrelic license key
cat > /etc/newrelic-infra.yml <<EOF
---
# New Relic config file
license_key: ${NR_LICENSE_KEY}
EOF
# Place file with rabbitmq config
cat > /etc/newrelic-infra/integrations.d/rabbitmq-config.yml <<EOF
integration_name: com.newrelic.rabbitmq

instances:
  - name: rabbit@spryker
    # Available commands are "all", "metrics", and "inventory"
    command: all
    arguments:
      port: ${RABBITMQ_PORT}
      Hostname: ${RABBITMQ_ENDPOINT}
      username: ${RABBITMQ_USERNAME}
      password: ${RABBITMQ_PASSWORD}
      use_ssl: ${RABBITMQ_USE_SSL}
      queues_regexes: ${RABBITMQ_QUEUES_REGEXES}
      exchanges_regexes: ${RABBITMQ_EXCHANGE_REGEXES}
      # queues_regexes: '["queue[0-9]+",".*"]'
      # exchanges_regexes: '["queue[0-9]+",".*"]'
      # config_path: ~/rabbitmq.conf
      # Hostname or IP of RabbitMQ host
      # hostname: ADD_HOSTNAME
      # port: mANAGEMENT_UI_PORT
      # username: MANAGEMENT_UI_USERNAME
      # password: MANAGEMENT_UI_PASSWORD
      # ca_bundle_dir: CA_BUNDLE_DIRECTORY
      # ca_bundle_file: CA_BUNDLE_FILE
      # node_name_override: LOCAL_NODE_NAME
      # # Boolean value, option to connect using SSL
      # # JSON array of queue names to collect
      # queues: sync.search.cms
      # # JSON array of regexes, matching queue names will be collected
      # queues_regexes: ARRAY_OF_QUEUE_REGEXES
      # # JSON array of exchange names to collect
      # exchanges: sync.search.cms
      # # JSON array of regexes, matching exchange names will be collected
      # exchanges_regexes: ARRAY_OF_EXCHANGE_REGEXES
      # # JSON array of vhost names to collect
      # vhosts: de_queue
      # # JSON array of regexes, entities assigned to vhosts matching a regex
      # # will be collected
      # vhosts_regexes: ARRAY_OF_HOST_REGEXE
    labels:
      env: production
      role: rabbitmq
EOF
exec "$@"