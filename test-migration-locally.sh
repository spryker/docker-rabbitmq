#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get the absolute path to the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to print colored output
print_colored() {
  printf "${2}%s${NC}\n" "$1"
}

print_colored "=== RabbitMQ 3.13 to 4.1 Migration Test ===" "$GREEN"

# Create a temporary directory for testing
TEST_DIR=$(mktemp -d -t rabbitmq-migration-test-XXXXXX)
cd "$TEST_DIR"
print_colored "Created temporary test directory: $TEST_DIR" "$YELLOW"

# Copy required scripts
print_colored "Copying migration script..." "$YELLOW"
cp "$SCRIPT_DIR/migrate-rabbitmq-3.13-to-4.1.sh" .
chmod +x migrate-rabbitmq-3.13-to-4.1.sh

# Create auto-migrate-startup.sh script
print_colored "Creating auto-migrate-startup.sh script..." "$YELLOW"
cat > auto-migrate-startup.sh << 'EOF'
#!/bin/bash
set -e

# Start RabbitMQ server in the background
rabbitmq-server -detached

# Wait for RabbitMQ to start
echo "Waiting for RabbitMQ to start..."
until rabbitmqctl status >/dev/null 2>&1; do
    sleep 1
done
echo "RabbitMQ is running"

# Check if source RabbitMQ is defined
if [ -n "$SOURCE_RABBITMQ_HOST" ]; then
    echo "Source RabbitMQ detected at $SOURCE_RABBITMQ_HOST, starting migration..."
    # Run the migration script
    /usr/local/bin/migrate-rabbitmq-3.13-to-4.1.sh
    echo "Migration completed"
else
    echo "No source RabbitMQ detected, starting as fresh instance"
fi

# Keep the container running with RabbitMQ in the foreground
echo "Starting RabbitMQ in foreground mode"
rabbitmqctl stop
exec rabbitmq-server
EOF
chmod +x auto-migrate-startup.sh

# Create test Dockerfile
print_colored "Creating test Dockerfile..." "$YELLOW"
cat > Dockerfile << 'EOF'
FROM rabbitmq:4.1-management-alpine

# Install required tools for migration and management
RUN apk add --no-cache jq curl

# Enable required plugins for RabbitMQ 4.1
RUN rabbitmq-plugins enable --offline rabbitmq_management \
    && rabbitmq-plugins enable --offline rabbitmq_management_agent \
    && rabbitmq-plugins enable --offline rabbitmq_prometheus \
    && rabbitmq-plugins enable --offline rabbitmq_shovel  \
    && rabbitmq-plugins enable --offline rabbitmq_shovel_management

# Copy the automatic migration startup script
COPY auto-migrate-startup.sh /usr/local/bin/auto-migrate-startup.sh
RUN chmod +x /usr/local/bin/auto-migrate-startup.sh

# Copy the migration script
COPY migrate-rabbitmq-3.13-to-4.1.sh /usr/local/bin/migrate-rabbitmq-3.13-to-4.1.sh
RUN chmod +x /usr/local/bin/migrate-rabbitmq-3.13-to-4.1.sh

# Use the automatic migration startup script
CMD ["auto-migrate-startup.sh"]
EOF

# Create Docker network
print_colored "Creating Docker network..." "$YELLOW"
docker network create rabbitmq-migration-test || echo "Network already exists"

# Clean up any existing containers
print_colored "Cleaning up any existing test containers..." "$YELLOW"
docker rm -f rabbitmq-3.13 rabbitmq-4.1 2>/dev/null || true

# Start RabbitMQ 3.13 container (source)
print_colored "Starting RabbitMQ 3.13 container..." "$YELLOW"
docker run -d --name rabbitmq-3.13 \
  --network rabbitmq-migration-test \
  -p 15672:15672 -p 5672:5672 \
  -e RABBITMQ_DEFAULT_USER=test \
  -e RABBITMQ_DEFAULT_PASS=test \
  spryker/rabbitmq:3.13

print_colored "Waiting for RabbitMQ 3.13 to start (30 seconds)..." "$YELLOW"
sleep 30

# Create test data in RabbitMQ 3.13
print_colored "Creating test data in RabbitMQ 3.13..." "$YELLOW"
docker exec rabbitmq-3.13 rabbitmqctl add_vhost test_vhost
docker exec rabbitmq-3.13 rabbitmqctl add_user test_user test_password
docker exec rabbitmq-3.13 rabbitmqctl set_permissions -p test_vhost test_user ".*" ".*" ".*"
docker exec rabbitmq-3.13 rabbitmqctl set_user_tags test_user administrator

# Wait for management plugin to be fully initialized
print_colored "Waiting for management plugin to initialize..." "$YELLOW"
sleep 30

# Create a test queue and publish messages
print_colored "Creating test queue and publishing messages..." "$YELLOW"
docker exec rabbitmq-3.13 rabbitmqctl eval 'rabbit_amqqueue:declare({resource, <<"test_vhost">>, queue, <<"test_queue">>}, true, false, [], none, "test_user").'

# Give test_user permissions to the default exchange in test_vhost
print_colored "Setting permissions for test_user on default exchange..." "$YELLOW"
docker exec rabbitmq-3.13 rabbitmqctl set_topic_permissions -p test_vhost test_user amq.default ".*" ".*"

# Publish messages using the management API with test_user credentials
print_colored "Publishing test messages..." "$YELLOW"
docker exec rabbitmq-3.13 apk add --no-cache curl
docker exec rabbitmq-3.13 curl -s -u test_user:test_password -H "content-type:application/json" \
  -X POST -d '{"properties":{},"routing_key":"test_queue","payload":"test message 1","payload_encoding":"string"}' \
  http://localhost:15672/api/exchanges/test_vhost/amq.default/publish

docker exec rabbitmq-3.13 curl -s -u test_user:test_password -H "content-type:application/json" \
  -X POST -d '{"properties":{},"routing_key":"test_queue","payload":"test message 2","payload_encoding":"string"}' \
  http://localhost:15672/api/exchanges/test_vhost/amq.default/publish

# Verify messages were published
print_colored "Verifying messages were published..." "$YELLOW"
docker exec rabbitmq-3.13 curl -s -u test_user:test_password http://localhost:15672/api/queues/test_vhost/test_queue | grep -o '"messages":[0-9]*' || echo "No messages found"

# Build the RabbitMQ 4.1 test image
print_colored "Building RabbitMQ 4.1 test image..." "$YELLOW"
docker build -t rabbitmq-4.1-migration-test .

# Run the RabbitMQ 4.1 container with migration
print_colored "Starting RabbitMQ 4.1 container with migration..." "$YELLOW"
docker run -d --name rabbitmq-4.1 \
  --network rabbitmq-migration-test \
  -p 15673:15672 -p 5673:5672 \
  -e SOURCE_RABBITMQ_HOST=rabbitmq-3.13 \
  -e SOURCE_RABBITMQ_PORT=5672 \
  -e SOURCE_RABBITMQ_MGMT_PORT=15672 \
  -e SOURCE_RABBITMQ_USER=test \
  -e SOURCE_RABBITMQ_PASS=test \
  -e TARGET_RABBITMQ_USER=guest \
  -e TARGET_RABBITMQ_PASS=guest \
  rabbitmq-4.1-migration-test

print_colored "Migration started! Showing logs from RabbitMQ 4.1 container..." "$GREEN"
print_colored "Press Ctrl+C to stop viewing logs (this will NOT stop the containers)" "$YELLOW"
docker logs -f rabbitmq-4.1

# This part will run after the user presses Ctrl+C to exit the logs
echo
print_colored "=== Migration Test Information ===" "$GREEN"
print_colored "RabbitMQ 3.13 Management UI: http://localhost:15672/ (user: test, pass: test)" "$YELLOW"
print_colored "RabbitMQ 4.1 Management UI: http://localhost:15673/ (user: guest, pass: guest)" "$YELLOW"
echo
print_colored "To verify migration, check that:" "$YELLOW"
echo "1. The test_vhost exists in RabbitMQ 4.1"
echo "2. The test_user exists with the same permissions"
echo "3. The test_queue exists and contains the messages"
echo
print_colored "To clean up when done testing:" "$YELLOW"
echo "docker stop rabbitmq-3.13 rabbitmq-4.1"
echo "docker rm rabbitmq-3.13 rabbitmq-4.1"
echo "docker network rm rabbitmq-migration-test"
echo "docker rmi rabbitmq-4.1-migration-test"
echo "rm -rf $TEST_DIR"
echo
print_colored "Test environment is now running!" "$GREEN"
