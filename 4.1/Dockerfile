FROM rabbitmq:4.1-management-alpine

RUN apk add --no-cache jq

RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management

COPY migrate-rabbitmq-3.13-to-4.1.sh /usr/local/bin/migrate-rabbitmq-3.13-to-4.1.sh
RUN chmod +x /usr/local/bin/migrate-rabbitmq-3.13-to-4.1.sh

CMD ["migrate-rabbitmq-3.13-to-4.1.sh"]
