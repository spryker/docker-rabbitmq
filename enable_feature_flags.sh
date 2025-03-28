#!/bin/sh

set -e

echo "Enabling feature flags..."

available_flags=$(rabbitmqctl list_feature_flags --formatter=json | jq -r '.[].name')

if [ -z "$available_flags" ]; then
    echo "No feature flags available or unable to retrieve feature flags."
    return 0
fi

echo "Available feature flags: $available_flags"

for flag in $available_flags; do
    echo "Enabling feature flag: $flag"
    if rabbitmqctl enable_feature_flag "$flag"; then
        echo "Feature flag enabled: $flag"
    else
        echo "Failed to enable feature flag: $flag"
    fi
done

echo "Feature flags configuration completed"
