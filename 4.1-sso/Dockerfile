FROM rabbitmq:4.1-management-alpine

RUN apk add --no-cache jq curl

RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management  \
    && rabbitmq-plugins enable --offline rabbitmq_auth_backend_oauth2

COPY 4.1/rabbitmq.conf /tmp/rabbitmq.conf.template
COPY rabbitmq-migration.sh /usr/local/bin/rabbitmq-migration.sh
RUN chmod +x /usr/local/bin/rabbitmq-migration.sh

CMD ["rabbitmq-migration.sh"]
