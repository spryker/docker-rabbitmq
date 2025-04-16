#!/bin/bash

set -e

IMAGE_TAG=$1

if [ -z "$IMAGE_TAG" ]; then
  echo "Error: No image tag provided"
  exit 1
fi

docker run --rm "$IMAGE_TAG" bash -c '
  echo "=== RabbitMQ Version ==="
  if command -v rabbitmqctl &> /dev/null; then
    rabbitmqctl version || echo "Failed to get RabbitMQ version"
  else
    echo "rabbitmqctl not found"
  fi

  echo ""
  echo "=== Erlang Version ==="
  if command -v erl &> /dev/null; then
    erl -noshell -eval "erlang:display(erlang:system_info(otp_release)), halt()."
  else
    echo "Erlang not installed"
  fi

  echo ""
  echo "=== OS Release ==="
  if [ -f /etc/os-release ]; then
    cat /etc/os-release
  else
    echo "Unknown"
  fi

  echo ""
  echo "=== Installed APT Packages ==="
  if command -v dpkg &> /dev/null; then
    dpkg -l | awk '\''{ print $2 " " $3 }'\'' | sort
  elif command -v apk &> /dev/null; then
    apk info -vv
  else
    echo "Package manager not found"
  fi

  echo ""
  echo "=== Environment Variables ==="
  printenv | sort

  echo ""
  echo "=== RabbitMQ Enabled Plugins ==="
  if command -v rabbitmq-plugins &> /dev/null; then
    rabbitmq-plugins list -E -m || echo "Failed to list plugins"
  else
    echo "rabbitmq-plugins not found"
  fi
'
