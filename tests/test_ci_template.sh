#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_TEMPLATE="$SCRIPT_DIR/../ci/aria-review.yml"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Prints one key of the ai_code_review job as JSON ("null" when the key is missing)
job_key() {
  python3 -c "
import sys, json, yaml
print(json.dumps(yaml.safe_load(open(sys.argv[1]))['ai_code_review'].get(sys.argv[2])))
" "$CI_TEMPLATE" "$1" || fail "could not read ai_code_review.$1 from ci/aria-review.yml (needs python3 + pyyaml)"
}

# Test 1: the job asks for a Docker-executor runner by tag.
# A shell executor ignores image:, so an untagged job can land on a shell runner
# (e.g. one tagged "local" that also runs untagged jobs) where the ARIA tools are missing.
job_key tags | jq -e 'index("docker") != null' > /dev/null \
  || fail "ai_code_review must have tags: [docker], got: $(job_key tags)"
pass "job is tagged for a Docker-executor runner"

# Test 2: the job clears any inherited before_script.
# A project's global before_script (e.g. apt-get install) would otherwise run before the
# review, and the ARIA image already has every tool it needs.
[[ "$(job_key before_script)" == "[]" ]] \
  || fail "ai_code_review must set before_script: [], got: $(job_key before_script)"
pass "job overrides inherited before_script with an empty list"

# Test 3: on a runner without the ARIA image the job fails at once with a clear message,
# not with "generate-opencode-config.sh: command not found" halfway through.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
job_script=$(python3 -c "
import sys, yaml
print('\n'.join(yaml.safe_load(open(sys.argv[1]))['ai_code_review']['script']))
" "$CI_TEMPLATE")
cd "$WORK"
output=$(PATH=/usr/bin:/bin CI_PROJECT_DIR="$WORK" CI_RUNNER_DESCRIPTION=local-runner \
  bash -eo pipefail -c "$job_script" 2>&1) && fail "expected non-zero exit without the ARIA tools on PATH" || true
echo "$output" | grep -q "ARIA_REVIEW_IMAGE" \
  || fail "error must mention ARIA_REVIEW_IMAGE; got: $output"
echo "$output" | grep -qi "docker executor" \
  || fail "error must say a Docker executor is needed; got: $output"
echo "$output" | grep -q "command not found" \
  && fail "job must stop before any 'command not found'; got: $output"
pass "fails fast with a clear message when the ARIA tools are not on PATH"

echo ""
echo "All CI template tests passed."
