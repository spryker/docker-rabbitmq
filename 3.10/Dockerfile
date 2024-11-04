FROM rabbitmq:3.10-management-alpine

RUN apk add --no-cache jq

ARG RABBITMQ_SERVER_CODE_PATH=/rabbitmq_hipe
ENV RABBITMQ_SERVER_CODE_PATH=${RABBITMQ_SERVER_CODE_PATH}
RUN rabbitmqctl hipe_compile ${RABBITMQ_SERVER_CODE_PATH}

COPY enable_feature_flags.sh /usr/local/bin/enable_feature_flags.sh
RUN chmod +x /usr/local/bin/enable_feature_flags.sh

CMD ["sh", "-c", "rabbitmq-server & sleep 90 && /usr/local/bin/enable_feature_flags.sh && wait"]
