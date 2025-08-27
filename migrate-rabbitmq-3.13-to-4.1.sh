#!/bin/bash

set -e

set -m

terminate() {
    echo >&2 "Caught SIGTERM, forwarding to children..."
    kill -- -$$  # Send SIGTERM to the entire process group
    echo >&2 "Waiting for child processes to terminate..."
    wait
    echo >&2 "All processes terminated, exiting with code 0"
    exit 0  # Exit with 0 instead of 143
}

trap 'terminate' SIGTERM

SOURCE_RABBITMQ_HOST="${SOURCE_RABBITMQ_HOST:-source-rabbitmq}"
SOURCE_RABBITMQ_PORT="${SOURCE_RABBITMQ_PORT:-5672}"
SOURCE_RABBITMQ_MGMT_PORT="${SOURCE_RABBITMQ_MGMT_PORT:-15672}"
SOURCE_RABBITMQ_USER="${SOURCE_RABBITMQ_USER:-guest}"
SOURCE_RABBITMQ_PASS="${SOURCE_RABBITMQ_PASS:-guest}"

TARGET_RABBITMQ_HOST="${TARGET_RABBITMQ_HOST:-localhost}"
TARGET_RABBITMQ_PORT="${TARGET_RABBITMQ_PORT:-5672}"
TARGET_RABBITMQ_MGMT_PORT="${TARGET_RABBITMQ_MGMT_PORT:-15672}"
TARGET_RABBITMQ_USER="${TARGET_RABBITMQ_USER:-guest}"
TARGET_RABBITMQ_PASS="${TARGET_RABBITMQ_PASS:-guest}"

MIGRATION_TIMEOUT="${MIGRATION_TIMEOUT:-3600}"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required tools
check_requirements() {
    echo >&2 "Checking requirements..."

    if ! command_exists jq; then
        echo >&2 "Error: jq is required but not installed. Please install jq."
        exit 1
    fi

    if ! command_exists curl; then
        echo >&2 "Error: curl is required but not installed. Please install curl."
        exit 1
    fi

    echo >&2 "All requirements satisfied."
}

# Function to wait for RabbitMQ to be ready
wait_for_rabbitmq() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4
    local max_attempts=30
    local attempt=0

    echo >&2 "Waiting for RabbitMQ at $host:$port to become available..."

    while [ $attempt -lt $max_attempts ]; do
        if curl -s -u "$user:$pass" "http://$host:$port/api/overview" > /dev/null 2>&1; then
            echo >&2 "RabbitMQ at $host:$port is ready."
            return 0
        fi

        attempt=$((attempt + 1))
        echo >&2 "Attempt $attempt/$max_attempts: RabbitMQ at $host:$port is not ready yet. Waiting..."
        sleep 5
    done

    echo >&2 "Error: RabbitMQ at $host:$port did not become available within the timeout period."
    return 1
}

# Function to migrate vhosts
migrate_vhosts() {
    echo >&2 "Migrating vhosts..."

    # Get list of vhosts from source
    local vhosts_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
        "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/vhosts")

    # Check if we got valid JSON
    if ! echo "$vhosts_json" | jq empty > /dev/null 2>&1; then
        echo >&2 "Error: Failed to get vhosts from source RabbitMQ. Response was not valid JSON."
        return 1
    fi

    # Extract vhost names
    local vhosts=$(echo "$vhosts_json" | jq -r '.[] | select(.name != null) | .name')

    # Create vhosts on target (skip default vhost '/')
    for vhost in $vhosts; do
        if [ "$vhost" != "/" ]; then
            echo >&2 "Creating vhost: $vhost"
            curl -s -u "$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS" \
                -X PUT "http://$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_MGMT_PORT/api/vhosts/$vhost" \
                -H "Content-Type: application/json" \
                -d '{}'
        fi
    done

    echo >&2 "Vhosts migration completed."
}

# Function to migrate users and permissions
migrate_users_and_permissions() {
    echo >&2 "Migrating users and permissions..."

    # Export user definitions from source (includes password hashes)
    echo >&2 "Exporting user definitions from source RabbitMQ..."
    local definitions=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
        "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/definitions")

    # Check if we got valid JSON
    if ! echo "$definitions" | jq empty > /dev/null 2>&1; then
        echo >&2 "Error: Failed to get definitions from source RabbitMQ. Response was not valid JSON."
        return 1
    fi

    # Extract users (excluding guest user to avoid conflicts)
    local users=$(echo "$definitions" | jq '.users | map(select(.name != "guest"))')

    # Check if users is not null or empty
    if [ "$users" != "[]" ] && [ "$users" != "null" ]; then
        echo >&2 "Importing users with original password hashes..."

        # Create a temporary definitions file with just users
        local temp_definitions=$(echo '{}' | jq --argjson users "$users" '.users = $users')

        # Import users to target RabbitMQ (this preserves password hashes)
        echo "$temp_definitions" | curl -s -u "$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS" \
            -X POST "http://$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_MGMT_PORT/api/definitions" \
            -H "Content-Type: application/json" \
            -d @-

        echo >&2 "Users imported successfully with original passwords preserved."
    else
        echo >&2 "No additional users found to migrate."
    fi

    # Extract permissions
    local permissions=$(echo "$definitions" | jq '.permissions // []')

    # Check if permissions is not null or empty
    if [ "$permissions" != "[]" ] && [ "$permissions" != "null" ]; then
        echo >&2 "Importing permissions..."

        # Create a temporary definitions file with just permissions
        local temp_definitions=$(echo '{}' | jq --argjson permissions "$permissions" '.permissions = $permissions')

        # Import permissions to target RabbitMQ
        echo "$temp_definitions" | curl -s -u "$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS" \
            -X POST "http://$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_MGMT_PORT/api/definitions" \
            -H "Content-Type: application/json" \
            -d @-

        echo >&2 "Permissions imported successfully."
    else
        echo >&2 "No permissions found to migrate."
    fi

    echo >&2 "Users and permissions migration completed."
}

# Function to migrate policies
migrate_policies() {
    echo >&2 "Migrating policies..."

    local vhosts_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
        "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/vhosts")

    # Check if we got valid JSON
    if ! echo "$vhosts_json" | jq empty > /dev/null 2>&1; then
        echo >&2 "Error: Failed to get vhosts from source RabbitMQ. Response was not valid JSON."
        return 1
    fi

    # Extract vhost names
    local vhosts=$(echo "$vhosts_json" | jq -r '.[] | select(.name != null) | .name')

    for vhost in $vhosts; do
        local policies_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
            "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/policies/$vhost")

        # Check if we got valid JSON
        if ! echo "$policies_json" | jq empty > /dev/null 2>&1; then
            echo >&2 "Warning: Failed to get policies for vhost $vhost. Skipping."
            continue
        fi

        # Check if the response is an array and not empty
        if [ "$(echo "$policies_json" | jq 'if type=="array" then length else 0 end')" -eq 0 ]; then
            echo >&2 "No policies found for vhost: $vhost"
            continue
        fi

        echo "$policies_json" | jq -c '.[]?' | while read -r policy; do
            # Skip if policy is null or empty
            if [ -z "$policy" ] || [ "$policy" = "null" ]; then
                continue
            fi

            # Extract policy details with null checks
            local name=$(echo "$policy" | jq -r '.name // empty')
            if [ -z "$name" ]; then
                echo >&2 "Warning: Policy without name found, skipping."
                continue
            fi

            local pattern=$(echo "$policy" | jq -r '.pattern // ""')
            local apply_to=$(echo "$policy" | jq -r '.["apply-to"] // "queues"')
            local definition=$(echo "$policy" | jq -r '.definition // {}')
            local priority=$(echo "$policy" | jq -r '.priority // 0')

            echo >&2 "Creating policy: $name on vhost: $vhost"

            # URL encode the vhost name
            local encoded_vhost=$(printf '%s' "$vhost" | jq -sRr @uri)

            # Remove ha-mode and ha-sync-mode from definition if present
            # These are not compatible with RabbitMQ 4.x
            definition=$(echo "$definition" | jq 'del(.["ha-mode", "ha-sync-mode"])')

            curl -s -u "$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS" \
                -X PUT "http://$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_MGMT_PORT/api/policies/$encoded_vhost/$name" \
                -H "Content-Type: application/json" \
                -d "{\"pattern\":\"$pattern\",\"definition\":$definition,\"priority\":$priority,\"apply-to\":\"$apply_to\"}"
        done
    done

    echo >&2 "Policies migration completed."
}

# Function to set up shovels for queue migration
setup_shovels() {
    echo >&2 "Setting up shovels for queue migration..."

    local vhosts_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
        "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/vhosts")

    # Check if we got valid JSON
    if ! echo "$vhosts_json" | jq empty > /dev/null 2>&1; then
        echo >&2 "Error: Failed to get vhosts from source RabbitMQ. Response was not valid JSON."
        return 1
    fi

    # Extract vhost names
    local vhosts=$(echo "$vhosts_json" | jq -r '.[] | select(.name != null) | .name')

    for vhost in $vhosts; do
        echo >&2 "Processing vhost: $vhost"

        # Get queues in the source vhost
        local queues_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
            "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/queues/$vhost")

        # Check if we got valid JSON
        if ! echo "$queues_json" | jq empty > /dev/null 2>&1; then
            echo >&2 "Warning: Failed to get queues for vhost $vhost. Skipping."
            continue
        fi

        # Check if the response is an array and not empty
        if [ "$(echo "$queues_json" | jq 'if type=="array" then length else 0 end')" -eq 0 ]; then
            echo >&2 "No queues found for vhost: $vhost"
            continue
        fi

        echo "$queues_json" | jq -c '.[]?' | while read -r queue_data; do
            # Skip if queue_data is null or empty
            if [ -z "$queue_data" ] || [ "$queue_data" = "null" ]; then
                continue
            fi

            local queue_name=$(echo "$queue_data" | jq -r '.name // empty')
            if [ -z "$queue_name" ]; then
                echo >&2 "Warning: Queue without name found, skipping."
                continue
            fi

            local queue_type=$(echo "$queue_data" | jq -r '.arguments."x-queue-type" // "classic"')

            # Skip temporary queues
            if [[ "$queue_name" == *temporary_* ]]; then
                echo >&2 "Skipping temporary queue: $queue_name"
                continue
            fi

            echo >&2 "Setting up shovel for queue: $queue_name (type: $queue_type)"

            # URL encode the queue name and vhost
            local encoded_queue=$(printf '%s' "$queue_name" | jq -sRr @uri)
            local encoded_vhost=$(printf '%s' "$vhost" | jq -sRr @uri)

            # Create the queue on the target with quorum type
            curl -s -u "$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS" \
                -X PUT "http://$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_MGMT_PORT/api/queues/$encoded_vhost/$encoded_queue" \
                -H "Content-Type: application/json" \
                -d '{"durable":true,"arguments":{"x-queue-type":"quorum"}}'

            # Create a shovel on the source to move messages to the target
            local shovel_config="{
                \"src-uri\": \"amqp://$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS@$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_PORT/$encoded_vhost\",
                \"src-queue\": \"$encoded_queue\",
                \"dest-uri\": \"amqp://$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS@$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_PORT/$encoded_vhost\",
                \"dest-queue\": \"$encoded_queue\",
                \"ack-mode\": \"on-confirm\",
                \"delete-after\": \"never\"
            }"

            curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
                -X PUT "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/parameters/shovel/$vhost/migrate_to_4.1_$queue_name" \
                -H "Content-Type: application/json" \
                -d "{\"value\":$shovel_config}"
        done
    done

    echo >&2 "Shovels setup completed."
}

# Function to monitor migration progress
monitor_migration() {
    echo >&2 "Monitoring migration progress..."

    local start_time=$(date +%s)
    local timeout=$MIGRATION_TIMEOUT

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            echo >&2 "Migration timeout reached after $elapsed seconds."
            break
        fi

        local all_queues_empty=true
        local vhosts_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
            "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/vhosts")

        # Check if we got valid JSON
        if ! echo "$vhosts_json" | jq empty > /dev/null 2>&1; then
            echo >&2 "Error: Failed to get vhosts from source RabbitMQ. Retrying in 30 seconds..."
            sleep 30
            continue
        fi

        # Extract vhost names
        local vhosts=$(echo "$vhosts_json" | jq -r '.[] | select(.name != null) | .name')

        for vhost in $vhosts; do
            local queues_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
                "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/queues/$vhost")

            # Check if we got valid JSON
            if ! echo "$queues_json" | jq empty > /dev/null 2>&1; then
                echo >&2 "Warning: Failed to get queues for vhost $vhost. Skipping."
                continue
            fi

            # Check if the response is an array and not empty
            if [ "$(echo "$queues_json" | jq 'if type=="array" then length else 0 end')" -eq 0 ]; then
                echo >&2 "No queues found for vhost: $vhost"
                continue
            fi

            echo "$queues_json" | jq -c '.[]?' | while read -r queue_data; do
                # Skip if queue_data is null or empty
                if [ -z "$queue_data" ] || [ "$queue_data" = "null" ]; then
                    continue
                fi

                local queue_name=$(echo "$queue_data" | jq -r '.name // empty')
                if [ -z "$queue_name" ]; then
                    continue
                fi

                local messages=$(echo "$queue_data" | jq -r '.messages // 0')

                # Skip temporary queues
                if [[ "$queue_name" == *temporary_* ]]; then
                    continue
                fi

                if [[ $messages -gt 0 ]]; then
                    all_queues_empty=false
                    echo >&2 "Queue $queue_name in vhost $vhost still has $messages messages."
                fi
            done
        done

        if $all_queues_empty; then
            echo >&2 "All queues are empty. Migration completed successfully."
            break
        fi

        echo >&2 "Migration in progress. Elapsed time: $elapsed seconds. Checking again in 30 seconds..."
        sleep 30
    done
}

# Function to verify migration
verify_migration() {
    echo >&2 "Verifying migration..."

    local source_vhosts_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
        "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/vhosts")

    # Check if we got valid JSON
    if ! echo "$source_vhosts_json" | jq empty > /dev/null 2>&1; then
        echo >&2 "Error: Failed to get vhosts from source RabbitMQ. Response was not valid JSON."
        return 1
    fi

    # Extract vhost names
    local source_vhosts=$(echo "$source_vhosts_json" | jq -r '.[] | select(.name != null) | .name')

    local target_vhosts_json=$(curl -s -u "$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS" \
        "http://$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_MGMT_PORT/api/vhosts")

    # Check if we got valid JSON
    if ! echo "$target_vhosts_json" | jq empty > /dev/null 2>&1; then
        echo >&2 "Error: Failed to get vhosts from target RabbitMQ. Response was not valid JSON."
        return 1
    fi

    # Extract vhost names
    local target_vhosts=$(echo "$target_vhosts_json" | jq -r '.[] | select(.name != null) | .name')

    # Check if all vhosts were migrated
    for vhost in $source_vhosts; do
        if ! echo "$target_vhosts" | grep -q "^$vhost$"; then
            echo >&2 "Warning: Vhost $vhost was not migrated to the target."
        fi
    done

    # Check if all queues were migrated
    for vhost in $source_vhosts; do
        local source_queues_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
            "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/queues/$vhost")

        # Check if we got valid JSON
        if ! echo "$source_queues_json" | jq empty > /dev/null 2>&1; then
            echo >&2 "Warning: Failed to get queues for vhost $vhost. Skipping."
            continue
        fi

        # Check if the response is an array and not empty
        if [ "$(echo "$source_queues_json" | jq 'if type=="array" then length else 0 end')" -eq 0 ]; then
            echo >&2 "No queues found for vhost: $vhost"
            continue
        fi

        local target_queues_json=$(curl -s -u "$TARGET_RABBITMQ_USER:$TARGET_RABBITMQ_PASS" \
            "http://$TARGET_RABBITMQ_HOST:$TARGET_RABBITMQ_MGMT_PORT/api/queues/$vhost")

        # Check if we got valid JSON
        if ! echo "$target_queues_json" | jq empty > /dev/null 2>&1; then
            echo >&2 "Warning: Failed to get queues for vhost $vhost. Skipping."
            continue
        fi

        # Check if the response is an array and not empty
        if [ "$(echo "$target_queues_json" | jq 'if type=="array" then length else 0 end')" -eq 0 ]; then
            echo >&2 "No queues found for vhost: $vhost"
            continue
        fi

        echo "$source_queues_json" | jq -c '.[]?' | while read -r queue_data; do
            # Skip if queue_data is null or empty
            if [ -z "$queue_data" ] || [ "$queue_data" = "null" ]; then
                continue
            fi

            local queue_name=$(echo "$queue_data" | jq -r '.name // empty')
            if [ -z "$queue_name" ]; then
                continue
            fi

            # Skip temporary queues
            if [[ "$queue_name" == *temporary_* ]]; then
                continue
            fi

            if ! echo "$target_queues_json" | jq -c '.[]?' | grep -q "\"name\":\"$queue_name\""; then
                echo >&2 "Warning: Queue $queue_name in vhost $vhost was not migrated to the target."
            fi
        done
    done

    echo >&2 "Migration verification completed."
}

# Function to clean up shovels
cleanup_shovels() {
    echo >&2 "Cleaning up shovels..."

    local vhosts_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
        "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/vhosts")

    # Check if we got valid JSON
    if ! echo "$vhosts_json" | jq empty > /dev/null 2>&1; then
        echo >&2 "Error: Failed to get vhosts from source RabbitMQ. Response was not valid JSON."
        return 1
    fi

    # Extract vhost names
    local vhosts=$(echo "$vhosts_json" | jq -r '.[] | select(.name != null) | .name')

    for vhost in $vhosts; do
        local shovels_json=$(curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
            "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/parameters/shovel/$vhost")

        # Check if we got valid JSON
        if ! echo "$shovels_json" | jq empty > /dev/null 2>&1; then
            echo >&2 "Warning: Failed to get shovels for vhost $vhost. Skipping."
            continue
        fi

        # Check if the response is an array and not empty
        if [ "$(echo "$shovels_json" | jq 'if type=="array" then length else 0 end')" -eq 0 ]; then
            echo >&2 "No shovels found for vhost: $vhost"
            continue
        fi

        echo "$shovels_json" | jq -c '.[]?' | while read -r shovel; do
            # Skip if shovel is null or empty
            if [ -z "$shovel" ] || [ "$shovel" = "null" ]; then
                continue
            fi

            local shovel_name=$(echo "$shovel" | jq -r '.name // empty')
            if [ -z "$shovel_name" ]; then
                continue
            fi

            if [[ "$shovel_name" == migrate_to_4.1_* ]]; then
                echo >&2 "Deleting shovel: $shovel_name from vhost: $vhost"
                curl -s -u "$SOURCE_RABBITMQ_USER:$SOURCE_RABBITMQ_PASS" \
                    -X DELETE "http://$SOURCE_RABBITMQ_HOST:$SOURCE_RABBITMQ_MGMT_PORT/api/parameters/shovel/$vhost/$shovel_name"
            fi
        done
    done

    echo >&2 "Shovel cleanup completed."
}

# Main migration function
perform_migration() {
    echo >&2 "Starting RabbitMQ 3.13 to 4.1 migration..."

    # Check requirements
    check_requirements

    # Wait for source and target RabbitMQ to be ready
    wait_for_rabbitmq "$SOURCE_RABBITMQ_HOST" "$SOURCE_RABBITMQ_MGMT_PORT" "$SOURCE_RABBITMQ_USER" "$SOURCE_RABBITMQ_PASS"
    wait_for_rabbitmq "$TARGET_RABBITMQ_HOST" "$TARGET_RABBITMQ_MGMT_PORT" "$TARGET_RABBITMQ_USER" "$TARGET_RABBITMQ_PASS"

    # Migrate configurations
    migrate_vhosts
    migrate_users_and_permissions
    migrate_policies

    # Set up shovels for data migration
    setup_shovels

    # Monitor migration progress
    monitor_migration

    # Verify migration
    verify_migration

    # Clean up
    cleanup_shovels

    echo >&2 "Migration from RabbitMQ 3.13 to 4.1 completed successfully."
    echo >&2 "Please update your application configurations to point to the new RabbitMQ 4.1 cluster."
}

# Run the migration
perform_migration
