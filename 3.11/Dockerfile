FROM rabbitmq:3.11-management-alpine

RUN apk add --no-cache jq

COPY enable_feature_flags.sh /usr/local/bin/enable_feature_flags.sh
RUN chmod +x /usr/local/bin/enable_feature_flags.sh

CMD ["sh", "-c", "rabbitmq-server & sleep 60 && /usr/local/bin/enable_feature_flags.sh && wait"]
