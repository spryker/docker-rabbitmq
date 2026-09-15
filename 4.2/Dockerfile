FROM rabbitmq:4.2-management-alpine

RUN apk add --no-cache jq curl

RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management

ENV RABBITMQ_FEATURE_FLAGS=khepri_db
