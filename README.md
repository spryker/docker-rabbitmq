# RabbitMQ

## Description

Extends the official RabbitMQ management Alpine image with the plugins and tools required by Spryker.

* Based on: Official `RabbitMQ 4.1` and `RabbitMQ 4.2` (`rabbitmq:<version>-management-alpine`).
* Enabled plugins: `rabbitmq_management`, `rabbitmq_management_agent`, `rabbitmq_prometheus`, `rabbitmq_shovel`, `rabbitmq_shovel_management`.
* `-amqp1` variants additionally enable `rabbitmq_amqp1_0`.

> Note: Provided images require additional configuration for development, staging and production use.

## Tags

| Tag                                                                             | RabbitMQ version | Dockerfile                                                                             |
|:--------------------------------------------------------------------------------|:-----------------|:---------------------------------------------------------------------------------------|
| [spryker/rabbitmq:latest](https://hub.docker.com/r/spryker/rabbitmq/tags)       | 4.2              | [:link:](https://github.com/spryker/docker-rabbitmq/blob/master/4.2/Dockerfile)        |
| [spryker/rabbitmq:4.1](https://hub.docker.com/r/spryker/rabbitmq/tags)          | 4.1              | [:link:](https://github.com/spryker/docker-rabbitmq/blob/master/4.1/Dockerfile)        |
| [spryker/rabbitmq:4.1-amqp1](https://hub.docker.com/r/spryker/rabbitmq/tags)    | 4.1-amqp1        | [:link:](https://github.com/spryker/docker-rabbitmq/blob/master/4.1/amqp1/Dockerfile)  |
| [spryker/rabbitmq:4.1-shovel](https://hub.docker.com/r/spryker/rabbitmq/tags)   | 4.1-shovel       | [:link:](https://github.com/spryker/docker-rabbitmq/blob/master/4.1/shovel/Dockerfile) |
| [spryker/rabbitmq:4.2](https://hub.docker.com/r/spryker/rabbitmq/tags)          | 4.2              | [:link:](https://github.com/spryker/docker-rabbitmq/blob/master/4.2/Dockerfile)        |
| [spryker/rabbitmq:4.2-amqp1](https://hub.docker.com/r/spryker/rabbitmq/tags)    | 4.2-amqp1        | [:link:](https://github.com/spryker/docker-rabbitmq/blob/master/4.2/amqp1/Dockerfile)  |
| [spryker/rabbitmq:4.2-shovel](https://hub.docker.com/r/spryker/rabbitmq/tags)   | 4.2-shovel       | [:link:](https://github.com/spryker/docker-rabbitmq/blob/master/4.2/shovel/Dockerfile) |

## How to use

### Pull image
```bash
$ docker pull spryker/rabbitmq:4.2
```

### Dockerfile
```dockerfile
FROM spryker/rabbitmq:4.2
```

### docker-compose.yml
```yaml
broker:
    image: spryker/rabbitmq:4.2
```


## More information
* [RabbitMQ official images](https://github.com/docker-library/rabbitmq)
