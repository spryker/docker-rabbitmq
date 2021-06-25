FROM rabbitmq:3.7.14-management-alpine

ARG RABBITMQ_SERVER_CODE_PATH=/rabbitmq_hipe
ENV RABBITMQ_SERVER_CODE_PATH ${RABBITMQ_SERVER_CODE_PATH}

COPY 3.7.14/context/enabled_plugins /etc/rabbitmq/enabled_plugins

RUN rabbitmqctl hipe_compile ${RABBITMQ_SERVER_CODE_PATH}
