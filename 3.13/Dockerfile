# Use the official RabbitMQ image as the base image
FROM rabbitmq:3.13-management-alpine

RUN apk add --no-cache jq

# Enable required plugins (adjust these based on your needs)
RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management

COPY 3.13/setup_rabbitmq.sh /usr/local/bin/setup_rabbitmq.sh
RUN chmod +x /usr/local/bin/setup_rabbitmq.sh

CMD ["sh", "-c", "rabbitmq-server & sleep 60 && /usr/local/bin/setup_rabbitmq.sh && wait"]

#RUN apk --no-cache add curl wget jq
#RUN export CWPLUGIN=$(curl -s https://api.github.com/repos/noxdafox/rabbitmq-cloudwatch-exporter/releases/latest | jq -r '.assets[].browser_download_url') \
#    && for url in $CWPLUGIN; do wget -P /plugins $url; done
#RUN ls -l /plugins
#
#RUN rabbitmq-plugins --offline enable rabbitmq_cloudwatch_exporter
#
#COPY 3.13/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf