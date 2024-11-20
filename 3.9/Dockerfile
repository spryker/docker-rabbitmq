FROM rabbitmq:3.9-management-alpine

ARG RABBITMQ_SERVER_CODE_PATH=/rabbitmq_hipe
ENV RABBITMQ_SERVER_CODE_PATH ${RABBITMQ_SERVER_CODE_PATH}




# Install necessary tools
RUN apk --no-cache add curl wget jq

# Fetch the latest release assets and download them
RUN export CWPLUGIN=$(curl -s https://api.github.com/repos/noxdafox/rabbitmq-cloudwatch-exporter/releases/latest | jq -r '.assets[].browser_download_url') \
    && for url in $CWPLUGIN; do wget -P /plugins $url; done

# List downloaded files for verification



RUN ls -l /plugins

# Copy the RabbitMQ configuration file into the container
COPY 3.9/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf


# Enable the CloudWatch exporter plugin
RUN rabbitmq-plugins --offline enable rabbitmq_cloudwatch_exporter
RUN rabbitmq-plugins --offline enable rabbitmq_prometheus
RUN rabbitmqctl hipe_compile ${RABBITMQ_SERVER_CODE_PATH}