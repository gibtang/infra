#!/usr/bin/env bash
# close-pr-issues.sh - close the GitHub issues linked to the PR that produced a commit.
#
# Usage: close-pr-issues.sh <commit-sha> [comment]
#
# Designed for the post-deploy step in deploy.yml: given the SHA pushed to the
# default branch, find the merged PR that produced it and close the issues it
# references. Bookkeeping only — the deploy already succeeded, so this script
# never fails the calling workflow: per-issue problems log a WARNING and are
# skipped; the script always exits 0.
#
# Issue discovery (union, deduplicated, ascending):
#   - closingIssuesReferences ("Closes/Fixes/Resolves #N" in the PR body)
#   - every "#N" mention in the PR body that resolves to an open issue here
#
# No-ops (exit 0) when the commit has no merged PR (direct pushes) or the PR
# references no resolvable open issues.
#
# Env:
#   GH_TOKEN / GH_REPO  gh CLI auth + target repo (set by the workflow)
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <commit-sha> [comment]" >&2
  exit 1
fi
sha="$1"
comment="${2:-Closed via production deploy}"

# 1. Find the PR associated with this commit (empty array for direct pushes).
pr_json="$(gh api "repos/${GH_REPO}/commits/${sha}/pulls" 2>/dev/null || echo '[]')"
pr_number="$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    prs = json.load(sys.stdin)
except Exception:
    prs = []
merged = [p for p in prs if p.get("merged_at")]
print(merged[0]["number"] if merged else (prs[0]["number"] if prs else ""))
' 2>/dev/null || true)"

if [ -z "$pr_number" ]; then
  echo "No PR associated with ${sha}; nothing to close."
  exit 0
fi
echo "Found PR #${pr_number} for ${sha}"

# 2. Collect candidate issue numbers from the PR.
pr_info="$(gh pr view "$pr_number" --json closingIssuesReferences,body 2>/dev/null || echo '{}')"
candidates="$(printf '%s' "$pr_info" | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
nums = set()
for ref in (data.get("closingIssuesReferences") or []):
    n = ref.get("number")
    if n is not None:
        nums.add(int(n))
for m in re.findall(r"#(\d+)", data.get("body") or ""):
    nums.add(int(m))
print("\n".join(str(n) for n in sorted(nums)))
' 2>/dev/null || true)"

if [ -z "$candidates" ]; then
  echo "PR #${pr_number} references no issues; nothing to close."
  exit 0
fi

closed=0
failed=0
for n in $candidates; do
  state="$(gh issue view "$n" --json state 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("state", ""))
except Exception:
    print("")
' 2>/dev/null || true)"
  case "$state" in
    OPEN)
      if gh issue close "$n" --comment "$comment" >/dev/null 2>&1; then
        echo "Closed issue #${n}"
        closed=$((closed + 1))
      else
        echo "WARNING: failed to close issue #${n}" >&2
        failed=$((failed + 1))
      fi
      ;;
    CLOSED)
      echo "Issue #${n} already closed; skipping."
      ;;
    *)
      echo "#${n} is not an open issue in ${GH_REPO}; skipping."
      ;;
  esac
done

echo "Done: ${closed} closed, ${failed} failed."
exit 0
