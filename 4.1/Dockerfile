FROM rabbitmq:4.1-management-alpine

RUN apk add --no-cache jq curl python3

RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management

COPY rabbitmq-migration.sh /usr/local/bin/rabbitmq-migration.sh
RUN chmod +x /usr/local/bin/rabbitmq-migration.sh
ENV DO_MIGRATE_QUEUES=1

CMD ["rabbitmq-migration.sh"]

