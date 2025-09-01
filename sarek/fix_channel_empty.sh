#!/usr/bin/env bash
set -euo pipefail
file="main.nf"
grep -RIn --include='*.nf' -E 'Channel\.empty\(\s*\[\s*\]\s*\)|Channel\.empty\(\s*\[\s*\[\s*\]\s*\]\s*\)' . || {
  echo "No invalid Channel.empty([...]) found"; exit 0; }
cp -p "$file" "${file}.bak"
sed -i -E 's/Channel\.empty\(\s*\[\s*\]\s*\)/Channel.empty()/g' "$file"
echo "Patched. Diff:"
diff -u "${file}.bak" "$file" || true
echo "Re-scan:"
grep -RIn --include='*.nf' -E 'Channel\.empty\(\s*\[\s*\]\s*\)|Channel\.empty\(\s*\[\s*\[\s*\]\s*\]\s*\)' . || echo "✔ clean"
EOF
 chmod +x ./offline/fix_channel_empty.sh
 ./offline/fix_channel_empty.sh
