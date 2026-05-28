#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../resolve-profiles.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Test 1: ARIA_PROFILES unset → all 5 profiles
output=$(unset ARIA_PROFILES; "$SCRIPT")
[[ "$output" == "functional architecture security performance readability" ]] \
  || fail "expected all 5 profiles when ARIA_PROFILES unset, got: '$output'"
pass "unset ARIA_PROFILES returns all 5 profiles"

# Test 2: ARIA_PROFILES empty string → all 5 profiles
output=$(ARIA_PROFILES="" "$SCRIPT")
[[ "$output" == "functional architecture security performance readability" ]] \
  || fail "expected all 5 profiles when ARIA_PROFILES='', got: '$output'"
pass "empty ARIA_PROFILES returns all 5 profiles"

# Test 3: valid subset
output=$(ARIA_PROFILES="functional,readability" "$SCRIPT")
[[ "$output" == "functional readability" ]] \
  || fail "expected 'functional readability', got: '$output'"
pass "valid subset returns only selected profiles"

# Test 4: single valid profile
output=$(ARIA_PROFILES="security" "$SCRIPT")
[[ "$output" == "security" ]] \
  || fail "expected 'security', got: '$output'"
pass "single valid profile returns that profile"

# Test 5: unknown token → warning on stderr, skipped from output
output=$(ARIA_PROFILES="functional,bogus,readability" "$SCRIPT" 2>/tmp/aria_test_stderr)
[[ "$output" == "functional readability" ]] \
  || fail "expected 'functional readability' with bogus skipped, got: '$output'"
grep -q "bogus" /tmp/aria_test_stderr \
  || fail "expected warning about 'bogus' on stderr"
pass "unknown token is warned and skipped"

# Test 6: all tokens unknown → non-zero exit
ARIA_PROFILES="bogus,garbage" "$SCRIPT" 2>/dev/null && fail "expected non-zero exit for all-unknown profiles" || true
pass "all-unknown profiles exits non-zero"

# Test 7: whitespace tolerance
output=$(ARIA_PROFILES="functional, readability" "$SCRIPT")
[[ "$output" == "functional readability" ]] \
  || fail "expected whitespace trimmed, got: '$output'"
pass "whitespace around profile names is trimmed"

# Test 8: all 5 explicitly listed
output=$(ARIA_PROFILES="functional,architecture,security,performance,readability" "$SCRIPT")
[[ "$output" == "functional architecture security performance readability" ]] \
  || fail "expected all 5 in order, got: '$output'"
pass "all 5 profiles explicitly listed returns all 5"

echo ""
echo "All resolve-profiles tests passed."
