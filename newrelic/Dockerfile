FROM newrelic/infrastructure-bundle:2.5.0
COPY ./entrypoint.sh entrypoint.sh
RUN chmod +x entrypoint.sh
ENTRYPOINT ["./entrypoint.sh"]
CMD ["/usr/bin/newrelic-infra-service"]
