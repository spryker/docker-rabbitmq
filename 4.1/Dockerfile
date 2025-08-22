FROM rabbitmq:4.1-management-alpine

RUN apk add --no-cache jq

RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management

COPY setup-rabbitmq.sh /usr/local/bin/setup-rabbitmq.sh
RUN chmod +x /usr/local/bin/setup-rabbitmq.sh

CMD ["setup-rabbitmq.sh"]
