#!/bin/bash

# Generate cleaned diff (remove headers like ---/+++/@@)
diff -u previous-image-report.txt current-image-report.txt | grep -vE '^(---|\+\+\+|@@)' > diff-output.txt

# Save base64 of diff for later use (e.g., Slack notification)
DIFF_OUTPUT=$(base64 -w 0 diff-output.txt)
echo "DIFF_OUTPUT=$DIFF_OUTPUT" >> "$GITHUB_ENV"
