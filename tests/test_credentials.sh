#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../gitlab-mr-changed-files.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Test: should fail with a message about GITLAB_URL when it is not set
unset GITLAB_URL GITLAB_TOKEN 2>/dev/null || true
output=$("$SCRIPT" group/repo 1 2>&1) && fail "expected non-zero exit without GITLAB_URL" || true
echo "$output" | grep -qi "GITLAB_URL" || fail "error must mention GITLAB_URL; got: $output"
pass "exits with GITLAB_URL error when env var is missing"

# Test: should fail with a message about GITLAB_TOKEN when only URL is set
export GITLAB_URL="https://gitlab.example.com"
unset GITLAB_TOKEN 2>/dev/null || true
output=$("$SCRIPT" group/repo 1 2>&1) && fail "expected non-zero exit without GITLAB_TOKEN" || true
echo "$output" | grep -qi "GITLAB_TOKEN" || fail "error must mention GITLAB_TOKEN; got: $output"
pass "exits with GITLAB_TOKEN error when env var is missing"

echo ""
echo "All credential tests passed."
