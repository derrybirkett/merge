#!/usr/bin/env bash
set -euo pipefail

echo "=== Merge Agent Setup ==="
echo ""

# Create labels in the current repo
echo "Creating labels..."
gh label create "merge/ready"   --color "0075ca" --description "Queued for autonomous merge"  2>/dev/null \
  && echo "  Created: merge/ready" \
  || echo "  Already exists: merge/ready"
gh label create "merge/blocked" --color "e11d48" --description "Merge blocked by Merge agent" 2>/dev/null \
  && echo "  Created: merge/blocked" \
  || echo "  Already exists: merge/blocked"

# Optionally patch Council to apply merge/ready after council/approved
COUNCIL_SCRIPT=".github/scripts/run-council-review.sh"

if [[ -f "$COUNCIL_SCRIPT" ]]; then
  echo ""
  echo "Council detected at ${COUNCIL_SCRIPT}."
  read -rp "Apply merge/ready label automatically after council/approved? [y/N] " patch_council
  if [[ "$patch_council" =~ ^[Yy]$ ]]; then
    if grep -q "merge/ready" "$COUNCIL_SCRIPT"; then
      echo "Council script already patched — skipping."
    else
      # Insert merge/ready line after the council/approved label line using Python
      python3 - "$COUNCIL_SCRIPT" <<'PYEOF' || echo "  Patch failed — patch manually: add 'gh pr edit \"\$PR_NUMBER\" --add-label \"merge/ready\"' after the council/approved label line."
import sys
path = sys.argv[1]
content = open(path).read()
old = '  gh pr edit "$PR_NUMBER" --add-label "council/approved"'
new = old + '\n  gh pr edit "$PR_NUMBER" --add-label "merge/ready" 2>/dev/null || true'
if old not in content:
    print(f"ERROR: expected line not found in {path}. Patch manually.", file=sys.stderr)
    sys.exit(1)
open(path, 'w').write(content.replace(old, new, 1))
print(f"Patched {path}")
PYEOF
    fi
  else
    echo "Skipped Council patch. Apply merge/ready manually or re-run setup to patch later."
  fi
fi

echo ""
echo "Setup complete."
echo ""
echo "Next: copy .github/workflows/merge.yml from the submodule into your repo's .github/workflows/"
