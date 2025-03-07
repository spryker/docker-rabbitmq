FROM rabbitmq:3.13-management-alpine

RUN apk add --no-cache jq

RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management

COPY 3.13/setup_rabbitmq.sh /usr/local/bin/setup_rabbitmq.sh
RUN chmod +x /usr/local/bin/setup_rabbitmq.sh

CMD ["sh", "-c", "rabbitmq-server & sleep 7200 && /usr/local/bin/setup_rabbitmq.sh && wait"]
