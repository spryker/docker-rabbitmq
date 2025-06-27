#!/bin/bash

# Generate cleaned diff (remove headers like ---/+++/@@)
diff -u previous-image-report.txt current-image-report.txt | grep -vE '^(---|\+\+\+|@@)' > diff-output.txt

if [ ! -s diff-output.txt ]; then
  echo "✅ No differences detected between image reports."
  DIFF_OUTPUT=""
else
  echo "⚠️ Differences detected:"
  cat diff-output.txt
  DIFF_OUTPUT=$(base64 -w 0 diff-output.txt)
fi

# Export result to GITHUB_ENV
echo "DIFF_OUTPUT=$DIFF_OUTPUT" >> "$GITHUB_ENV"
