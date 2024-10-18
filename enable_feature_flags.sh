#!/bin/sh

set -e

echo "Enabling feature flags..."

available_flags=$(rabbitmqctl list_feature_flags --formatter=json | jq -r '.[].name')

if [ -z "$available_flags" ]; then
    echo "No feature flags available or unable to retrieve feature flags."
    return 1
fi

echo "Available feature flags: $available_flags"

for flag in $available_flags; do
    echo "Enabling feature flag: $flag"
    if ! rabbitmqctl enable_feature_flag "$flag"; then
        echo "Failed to enable feature flag: $flag"
    else
        echo "Feature flag enabled: $flag"
    fi
done

echo "Feature flags configuration completed"
