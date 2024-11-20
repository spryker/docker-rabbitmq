#!/bin/bash

set -e

# Reuse environment variables for RabbitMQ credentials and host
RABBITMQ_USER="${RABBITMQ_DEFAULT_USER:-guest}"
RABBITMQ_PASS="${RABBITMQ_DEFAULT_PASS:-guest}"
RABBITMQ_HOST="${HOSTNAME:-localhost}"

delete_tmp_queues() {
  queues=$(rabbitmqadmin -u $RABBITMQ_USER -p $RABBITMQ_PASS --vhost=gr-docker list queues name | grep temporary | awk '{print $2}')

  # Check if there are any queues to delete
  if [[ -z "$queues" ]]; then
    echo "No queues containing 'temporary' found."
    exit 0
  fi

  # Loop through the list of queues and delete each one
  for queue in $queues; do
    echo "Deleting queue: $queue"
    rabbitmqadmin -u $RABBITMQ_USER -p $RABBITMQ_PASS --vhost=gr-docker delete queue name=$queue
  done

  echo "All queues containing 'temporary' have been deleted."
}

enable_feature_flags() {
    echo "Enabling feature flags..."

    available_flags=$(rabbitmqctl list_feature_flags --formatter=json | jq -r '.[].name')

    if [ -z "$available_flags" ]; then
        echo "No feature flags available or unable to retrieve feature flags."
        return 1
    fi

    disabled_flags=${RABBITMQ_DISABLED_FEATURE_FLAGS:-"classic_queue_mirroring"}

    echo "Available feature flags: $available_flags"
    echo "Disabled feature flags: $disabled_flags"

    for flag in $available_flags; do
        if echo "$disabled_flags" | grep -qw "$flag"; then
            echo "Skipping disabled feature flag: $flag"
        else
            echo "Enabling feature flag: $flag"
            if ! rabbitmqctl enable_feature_flag "$flag"; then
                echo "Failed to enable feature flag: $flag"
            else
                echo "Feature flag enabled: $flag"
            fi
        fi
    done
}

update_policies() {
  # Get a list of all vhosts (excluding the default root vhost '/')
  vhosts=$(rabbitmqctl list_vhosts --formatter=json | jq -r '.[].name' | grep -v '^/$')

  for vhost in $vhosts; do
    echo "Processing vhost: $vhost"

    # List all policies in the virtual host
    policies=$(rabbitmqctl list_policies -p "$vhost" --formatter=json)

    # Loop through each policy
    echo "$policies" | jq -c '.[]' | while read -r policy; do
        # Extract policy details
        name=$(echo "$policy" | jq -r '.name')
        pattern=$(echo "$policy" | jq -r '.pattern')
        apply_to=$(echo "$policy" | jq -r '.apply_to')
        definition=$(echo "$policy" | jq -r '.definition')
        priority=$(echo "$policy" | jq -r '.priority')

        echo "Processing policy: $name on vhost: $vhost"

        # Set a default apply_to if it's null or empty
        if [[ "$apply_to" == "null" || -z "$apply_to" ]]; then
            echo "Setting 'apply-to' to 'queues' for policy: $name"
            apply_to="queues"  # Default to 'queues' if 'apply-to' is null
        fi

        # Check if the policy contains ha-mode
        if echo "$definition" | grep -q '"ha-mode"'; then
            echo "Policy '$name' contains 'ha-mode'. Updating to remove 'ha-mode'..."

            # Remove 'ha-mode' and 'ha-sync-mode'
            new_definition=$(echo "$definition" | jq 'del(.["ha-mode", "ha-sync-mode"])')

            # Update the policy
            rabbitmqctl set_policy "$name" "$pattern" "$new_definition" --priority "$priority" --apply-to "$apply_to" -p "$vhost"
            echo "Policy '$name' has been updated."
        else
            echo "Policy '$name' does not contain 'ha-mode'. Skipping..."
        fi
    done
  done
}

migrate_queues() {
    # Check if Shovel plugin is enabled
    if ! rabbitmq-plugins list | grep -q rabbitmq_shovel; then
        echo "Error: Shovel plugin is not enabled. Please enable it with: rabbitmq-plugins enable rabbitmq_shovel"
        return 1
    fi

    # Get a list of all vhosts
    vhosts=$(rabbitmqctl list_vhosts --formatter=json | jq -r '.[].name' | grep -v '^/$')

    for vhost in $vhosts; do
        echo "Checking vhost: $vhost"

        # Get the list of all queues in the vhost
        queues=$(rabbitmqadmin -V "$vhost" -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" list queues name --format=raw_json | jq -r '.[].name')

        if [ -z "$queues" ]; then
            echo "No queues found in vhost: $vhost. Skipping."
            continue
        fi

        for queue in $queues; do
            if [[ "$queue" == *temporary_* ]]; then
                echo "Skipping the queue: $queue"
                continue
            fi

            # Check if the queue is already a quorum queue
            queue_type=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list queues name arguments --format=raw_json | jq -r --arg queue "$queue" '.[] | select(.name==$queue) | .arguments."x-queue-type"')

            if [[ "$queue_type" == "quorum" ]]; then
                echo "Queue $queue is already a quorum queue. Skipping migration."
                continue
            fi

            queue_messages=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list queues name messages --format=raw_json | jq -r --arg queue "$queue" '.[] | select(.name==$queue) | .messages')

            if [[ "$queue_messages" == "0" ]]; then
                echo "Queue $queue is empty. Migrating directly to quorum queue type."

                # Delete the empty queue
                echo "Deleting the empty queue: $queue..."
                rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" delete queue name="$queue"

                # Recreate as a quorum queue
                echo "Recreating $queue as a quorum queue..."
                rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" declare queue name="$queue" durable=true arguments='{"x-queue-type":"quorum"}'

                echo "Queue $queue in vhost $vhost migrated successfully to quorum."
                continue
            fi

            TEMP_QUEUE="temporary_$queue"

            echo "Migrating queue: $queue in vhost: $vhost"

            # 1. Create a temporary queue
            echo "Creating temporary queue: $TEMP_QUEUE..."
            rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" declare queue name="$TEMP_QUEUE" durable=true

            # Check if temporary queue was created
            temp_queue_exists=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list queues name --format=raw_json | jq -r --arg TEMP_QUEUE "$TEMP_QUEUE" '.[] | select(.name==$TEMP_QUEUE) | .name')
            if [ -z "$temp_queue_exists" ]; then
                echo "Error: Failed to create temporary queue $TEMP_QUEUE. Skipping this queue."
                continue
            fi

            # 2. Create a Shovel to move messages from the original queue to the temporary queue
            echo "Creating Shovel to move messages from $queue to $TEMP_QUEUE..."

            # Handle special characters in queue names
            src_queue=$(printf '%s' "$queue" | jq -sRr @uri)
            dest_queue=$(printf '%s' "$TEMP_QUEUE" | jq -sRr @uri)

            shovel_config=$(cat <<EOF
{
  "src-uri": "amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@${RABBITMQ_HOST}/${vhost}",
  "src-queue": "${src_queue}",
  "dest-uri": "amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@${RABBITMQ_HOST}/${vhost}",
  "dest-queue": "${dest_queue}",
  "ack-mode": "on-confirm",
  "delete-after": "queue-length"
}
EOF
)

            # Validate JSON
            echo "$shovel_config" | jq . > /dev/null 2>&1 || { echo "Invalid JSON for shovel config"; continue; }

            echo "Debug: Creating shovel with the following parameters:"
            echo "Vhost: $vhost"
            echo "Queue: $queue"
            echo "Temp Queue: $TEMP_QUEUE"
            echo "Shovel Config: $shovel_config"

            if ! rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" declare parameter \
                name="shovel_to_temp_${queue}" \
                component=shovel \
                value="$shovel_config" 2>&1 | tee shovel_error.log; then
                echo "Error creating shovel. See shovel_error.log for details."
                continue
            fi

            # Check if shovel was created
            shovel_exists=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list parameters component name --format=raw_json | jq -r --arg NAME "shovel_to_temp_${queue}" '.[] | select(.name==$NAME) | .name')
            if [ -z "$shovel_exists" ]; then
                echo "Error: Failed to create shovel shovel_to_temp_${queue}. Skipping this queue."
                continue
            fi

            # 3. Wait for all messages to be moved to the temporary queue
            echo "Waiting for messages to be moved to $TEMP_QUEUE..."
            start_time=$(date +%s)
            timeout=300  # 5 minutes timeout
            while true; do
                queue_messages=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list queues name messages --format=raw_json | jq -r --arg queue "$queue" '.[] | select(.name==$queue) | .messages')
                temp_queue_messages=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list queues name messages --format=raw_json | jq -r --arg TEMP_QUEUE "$TEMP_QUEUE" '.[] | select(.name==$TEMP_QUEUE) | .messages')

                echo "Original queue ($queue) messages: $queue_messages"
                echo "Temporary queue ($TEMP_QUEUE) messages: $temp_queue_messages"

                current_time=$(date +%s)
                elapsed=$((current_time - start_time))

                if [[ "$queue_messages" == "0" ]]; then
                    echo "All messages moved from $queue to $TEMP_QUEUE."
                    break
                elif [[ $elapsed -ge $timeout ]]; then
                    echo "Timeout reached. Messages may not have been fully transferred."
                    break
                fi
                sleep 10
            done

            # 4. Delete the original queue
            echo "Deleting the original queue: $queue..."
            rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" delete queue name="$queue"

            # 5. Recreate the original queue as a quorum queue
            echo "Recreating $queue as a quorum queue..."
            rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" declare queue name="$queue" durable=true arguments='{"x-queue-type":"quorum"}'

            # 6. Create a Shovel to move messages back from the temporary queue to the original queue
            echo "Creating Shovel to move messages from $TEMP_QUEUE back to $queue..."
            shovel_config=$(cat <<EOF
{
  "src-uri": "amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@${RABBITMQ_HOST}/${vhost}",
  "src-queue": "${dest_queue}",
  "dest-uri": "amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@${RABBITMQ_HOST}/${vhost}",
  "dest-queue": "${src_queue}",
  "ack-mode": "on-confirm",
  "delete-after": "queue-length"
}
EOF
)
            if ! rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" declare parameter \
                name="shovel_to_original_${queue}" \
                component=shovel \
                value="$shovel_config" 2>&1 | tee shovel_error.log; then
                echo "Error creating shovel back to original queue. See shovel_error.log for details."
                continue
            fi

            # 7. Wait for all messages to be moved back to the original queue
            echo "Waiting for messages to be moved back to $queue..."
            start_time=$(date +%s)
            while true; do
                temp_queue_messages=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list queues name messages --format=raw_json | jq -r --arg TEMP_QUEUE "$TEMP_QUEUE" '.[] | select(.name==$TEMP_QUEUE) | .messages')
                original_queue_messages=$(rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" list queues name messages --format=raw_json | jq -r --arg queue "$queue" '.[] | select(.name==$queue) | .messages')

                echo "Temporary queue ($TEMP_QUEUE) messages: $temp_queue_messages"
                echo "Original queue ($queue) messages: $original_queue_messages"

                current_time=$(date +%s)
                elapsed=$((current_time - start_time))

                if [[ "$temp_queue_messages" == "0" ]]; then
                    echo "All messages moved back to $queue."
                    break
                elif [[ $elapsed -ge $timeout ]]; then
                    echo "Timeout reached. Messages may not have been fully transferred back."
                    break
                fi
                sleep 10
            done

            # 8. Delete the temporary queue
            echo "Deleting temporary queue: $TEMP_QUEUE..."
            rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" delete queue name="$TEMP_QUEUE"

            # 9. Remove Shovel configurations
            echo "Removing Shovel configurations..."
            rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" delete parameter name="shovel_to_temp_$queue" component=shovel || echo "Shovel to temp not found, skipping..."
            rabbitmqadmin -u "$RABBITMQ_USER" -p "$RABBITMQ_PASS" -V "$vhost" delete parameter name="shovel_to_original_$queue" component=shovel || echo "Shovel to original not found, skipping..."

            echo "Queue $queue in vhost $vhost migrated successfully to quorum."
        done

        rabbitmqctl set_policy LazyAndHAQuorum "^(?!amq\.).+" '{"queue-mode":"lazy","x-queue-type":"quorum"}' --priority 0 --apply-to queues -p $vhost

    done
}

#delete_tmp_queues
enable_feature_flags
#migrate_queues
update_policies

echo "RabbitMQ setup completed"