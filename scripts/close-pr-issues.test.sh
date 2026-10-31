#!/usr/bin/env bash
# Smoke test for close-pr-issues.sh using a stubbed gh CLI.
#
# Files consumed by the stub (created per test in $WORK):
#   pulls.json   response for `gh api repos/<repo>/commits/<sha>/pulls`
#   pr.json      response for `gh pr view <n> --json closingIssuesReferences,body`
#   states.txt   lines "<num>:<OPEN|CLOSED>" for `gh issue view <num> --json state`;
#                numbers absent from states.txt behave like non-issues (gh errors)
#   closed.log   written by the stub for every `gh issue close`
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$HERE/gh"' EXIT

make_stub_gh() {
  cat > "$HERE/gh" <<EOF
#!/usr/bin/env bash
cmd="\$1"; shift
case "\$cmd" in
  api)
    if [ -f "$WORK/pulls.json" ]; then cat "$WORK/pulls.json"; else exit 1; fi ;;
  pr)
    cat "$WORK/pr.json" ;;
  issue)
    sub="\$1"; num="\$2"
    if [ "\$sub" = "view" ]; then
      state=\$(grep -E "^\${num}:" "$WORK/states.txt" 2>/dev/null | cut -d: -f2)
      if [ -z "\$state" ]; then exit 1; fi
      echo "{\\"state\\":\\"\$state\\"}"
    elif [ "\$sub" = "close" ]; then
      echo "\$num" >> "$WORK/closed.log"
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$HERE/gh"
}

run_test() {
  local name="$1" expected_closed="$2"; shift 2
  echo -n "  $name ... "
  rm -f "$WORK/closed.log"
  set +e
  bash "$HERE/close-pr-issues.sh" "$@" > /tmp/out 2>&1
  actual_exit=$?
  set -e
  touch "$WORK/closed.log"
  got_closed="$(sort "$WORK/closed.log" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$actual_exit" = "0" ] && [ "$got_closed" = "$expected_closed" ]; then
    echo "OK"
  else
    echo "FAIL (exit=$actual_exit, closed='$got_closed', expected='$expected_closed')"
    cat /tmp/out
    return 1
  fi
}

export GH_REPO=gibtang/test-repo
export PATH="$HERE:$PATH"
SHA=deadbeef

# Test 1: direct push (no PR) -> nothing closed
make_stub_gh
echo '[]' > "$WORK/pulls.json"
run_test "no PR for sha" "" "$SHA"

# Test 2: PR closes keyword ref 101 (open), body mentions 102 (already closed),
# 103 (open), 999 (not an issue) -> closes 101 and 103
make_stub_gh
echo '[{"number": 7, "merged_at": "2026-10-31T00:00:00Z"}]' > "$WORK/pulls.json"
echo '{"closingIssuesReferences":[{"number":101}],"body":"Fixes login.\n\nAlso relates to #102 and #103.\nRef #999."}' > "$WORK/pr.json"
printf '101:OPEN\n102:CLOSED\n103:OPEN\n' > "$WORK/states.txt"
rm -f "$WORK/closed.log"
run_test "closes open referenced issues" "101 103" "$SHA" "Closing comment"

# Test 3: PR with no issue references -> nothing closed
make_stub_gh
echo '[{"number": 7, "merged_at": "2026-10-31T00:00:00Z"}]' > "$WORK/pulls.json"
echo '{"closingIssuesReferences":[],"body":"Just a tweak."}' > "$WORK/pr.json"
run_test "PR without issue refs" "" "$SHA"

# Test 4: gh api fails entirely (network) -> treated as no PR, exit 0
make_stub_gh
rm -f "$WORK/pulls.json"
run_test "api failure tolerated" "" "$SHA"

echo "All tests passed."
