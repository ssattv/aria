#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../generate-opencode-config.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Test 1: substitutes ARIA_REVIEW_PATH into all 5 agent external_directory entries
output=$(ARIA_REVIEW_PATH=/workspace "$SCRIPT")
for agent in review_functional review_architecture review_security review_performance review_readability; do
  echo "$output" | jq -e --arg agent "$agent" \
    '.agent[$agent].permission.external_directory | has("/workspace/*")' > /dev/null \
    || fail "agent $agent missing /workspace/* in external_directory"
done
pass "substitutes ARIA_REVIEW_PATH for all 5 agents"

# Test 2: model field injected when ARIA_MODEL is set
output=$(ARIA_REVIEW_PATH=/workspace ARIA_MODEL=openai/gpt-4o "$SCRIPT")
echo "$output" | jq -e '.model == "openai/gpt-4o"' > /dev/null \
  || fail "expected .model == openai/gpt-4o"
pass "injects ARIA_MODEL when set"

# Test 3: model field absent when ARIA_MODEL is not set
output=$(ARIA_REVIEW_PATH=/workspace "$SCRIPT")
echo "$output" | jq -e 'has("model") | not' > /dev/null \
  || fail "expected no .model key when ARIA_MODEL is unset"
pass "omits model field when ARIA_MODEL is not set"

# Test 4: provider.baseURL injected when ARIA_MODEL_BASE_URL is set
output=$(ARIA_REVIEW_PATH=/workspace ARIA_MODEL_BASE_URL=http://ollama:11434 "$SCRIPT")
echo "$output" | jq -e '.provider.baseURL == "http://ollama:11434"' > /dev/null \
  || fail "expected .provider.baseURL to be set"
pass "injects ARIA_MODEL_BASE_URL when set"

# Test 5: fails when ARIA_REVIEW_PATH is not set
unset ARIA_REVIEW_PATH 2>/dev/null || true
"$SCRIPT" 2>&1 && fail "expected non-zero exit when ARIA_REVIEW_PATH is unset" || true
pass "exits with error when ARIA_REVIEW_PATH is not set"

echo ""
echo "All generate-config tests passed."
