#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_TEMPLATE="$SCRIPT_DIR/../ci/aria-review.yml"
SHELL_TEMPLATE="$SCRIPT_DIR/../ci/aria-review-shell.yml"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Prints one key of the ai_code_review job as JSON ("null" when the key is missing)
# Usage: job_key <key> [template]   (template defaults to ci/aria-review.yml)
job_key() {
  python3 -c "
import sys, json, yaml
print(json.dumps(yaml.safe_load(open(sys.argv[1]))['ai_code_review'].get(sys.argv[2])))
" "${2:-$CI_TEMPLATE}" "$1" || fail "could not read ai_code_review.$1 from ${2:-$CI_TEMPLATE} (needs python3 + pyyaml)"
}

# Prints a list key (script, after_script) of the ai_code_review job as one bash script
job_script() {
  job_key "$1" "${2:-$CI_TEMPLATE}" | jq -r 'join("\n")'
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
export WORK
docker_script=$(job_script script)
output=$(cd "$WORK" && PATH=/usr/bin:/bin CI_PROJECT_DIR="$WORK" CI_RUNNER_DESCRIPTION=local-runner \
  bash -eo pipefail -c "$docker_script" 2>&1) && fail "expected non-zero exit without the ARIA tools on PATH" || true
echo "$output" | grep -q "ARIA_REVIEW_IMAGE" \
  || fail "error must mention ARIA_REVIEW_IMAGE; got: $output"
echo "$output" | grep -qi "docker executor" \
  || fail "error must say a Docker executor is needed; got: $output"
echo "$output" | grep -q "command not found" \
  && fail "job must stop before any 'command not found'; got: $output"
pass "fails fast with a clear message when the ARIA tools are not on PATH"

# ---- ci/aria-review-shell.yml: shell runner that starts the ARIA image with docker run ----

# Test 4: the shell template also clears any inherited before_script
[[ "$(job_key before_script "$SHELL_TEMPLATE")" == "[]" ]] \
  || fail "shell template must set before_script: [], got: $(job_key before_script "$SHELL_TEMPLATE")"
pass "shell template overrides inherited before_script with an empty list"

# A fake MR checkout: detached HEAD on refs/pipelines/<id>, target branch not fetched yet
mkdir -p "$WORK/origin" "$WORK/ci" "$WORK/bin"
git -C "$WORK/origin" init -q -b main
git -C "$WORK/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WORK/origin" checkout -q -b feature
git -C "$WORK/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m feature
git -C "$WORK/ci" init -q
git -C "$WORK/ci" remote add origin "$WORK/origin"
git -C "$WORK/ci" fetch -q origin +refs/heads/feature:refs/pipelines/42
git -C "$WORK/ci" checkout -q --detach refs/pipelines/42

# Fake docker: appends each argument on its own line to $WORK/docker.args, exits with $DOCKER_EXIT
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$WORK/docker.args"
exit "${DOCKER_EXIT:-0}"
EOF
chmod +x "$WORK/bin/docker"

shell_script=$(job_script script "$SHELL_TEMPLATE")
# Runs the shell template's script in the fake checkout; extra args go to env (e.g. -u VAR)
run_shell_job() {
  (cd "$WORK/ci" && env "$@" PATH="$WORK/bin:$PATH" CI_PROJECT_DIR="$WORK/ci" CI_JOB_ID=99 \
    CI_PROJECT_ID=1 CI_MERGE_REQUEST_IID=7 CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main \
    GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=secret-token-xyz \
    bash -eo pipefail -c "$shell_script")
}

# Test 5: runs the review inside the ARIA image with the checkout mounted at the same path
: > "$WORK/docker.args"
run_shell_job ARIA_REVIEW_IMAGE=example/aria:test 2>"$WORK/job.err" \
  || fail "shell job exited non-zero: $(tail -3 "$WORK/job.err")"
args=$(cat "$WORK/docker.args")
has_arg() { grep -qxF -- "$1" <<< "$args" || fail "docker run is missing argument '$1'; got: $(tr '\n' ' ' <<< "$args")"; }
has_arg run
has_arg --rm
has_arg always
has_arg "example/aria:test"
has_arg "$WORK/ci:$WORK/ci:z"
has_arg "$WORK/ci"
has_arg "$(id -u):$(id -g)"
for var in CI_PROJECT_DIR CI_PROJECT_ID CI_MERGE_REQUEST_IID CI_MERGE_REQUEST_TARGET_BRANCH_NAME \
           GITLAB_URL GITLAB_TOKEN ARIA_MODEL ARIA_MODEL_API_KEY ARIA_MODEL_BASE_URL ARIA_PROFILES; do
  has_arg "$var"
done
[[ "$(tail -1 <<< "$args")" == "aria-review-job.sh" ]] \
  || fail "aria-review-job.sh must be the command run in the container; got: $(tail -1 <<< "$args")"
pass "starts the ARIA image with the checkout mounted and the CI variables passed in"

# Test 6: secrets are passed by name only, never as values on the command line or in files
grep -q "secret-token-xyz" <<< "$args" && fail "GITLAB_TOKEN value appeared on the docker command line"
grep -rq "secret-token-xyz" --exclude-dir=.git "$WORK/ci" && fail "GITLAB_TOKEN value was written to a file in the checkout"
pass "passes secrets by name only (-e NAME), not by value"

# Test 7: the target branch is fetched on the host, where the runner's git credentials work
git -C "$WORK/ci" rev-parse --verify --quiet origin/main > /dev/null \
  || fail "shell job must fetch origin/main on the host before docker run"
pass "fetches the target branch on the host before starting the container"

# Test 8: a failing review fails the job
run_shell_job ARIA_REVIEW_IMAGE=example/aria:test DOCKER_EXIT=3 2>/dev/null \
  && fail "expected the job to fail when the container exits non-zero"
pass "fails the job when the container fails"

# Test 9: clear errors when docker or ARIA_REVIEW_IMAGE is missing
mkdir -p "$WORK/nodocker"
for tool in bash git env cat grep sed id; do ln -sf "$(command -v "$tool")" "$WORK/nodocker/$tool"; done
output=$(cd "$WORK/ci" && PATH="$WORK/nodocker" CI_PROJECT_DIR="$WORK/ci" CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main \
  ARIA_REVIEW_IMAGE=example/aria:test "$WORK/nodocker/bash" -eo pipefail -c "$shell_script" 2>&1) \
  && fail "expected non-zero exit without docker on PATH" || true
echo "$output" | grep -qi "docker not found" || fail "error must say docker was not found; got: $output"
output=$(run_shell_job -u ARIA_REVIEW_IMAGE 2>&1) && fail "expected non-zero exit without ARIA_REVIEW_IMAGE" || true
echo "$output" | grep -q "ARIA_REVIEW_IMAGE" || fail "error must mention ARIA_REVIEW_IMAGE; got: $output"
pass "fails with a clear message when docker or ARIA_REVIEW_IMAGE is missing"

# Test 10: after_script removes the container, so a cancelled job leaves nothing running
: > "$WORK/docker.args"
(PATH="$WORK/bin:$PATH" CI_JOB_ID=99 bash -c "$(job_script after_script "$SHELL_TEMPLATE")") \
  || fail "after_script must not fail"
grep -qxF "rm" "$WORK/docker.args" && grep -qxF "aria-review-99" "$WORK/docker.args" \
  || fail "after_script must run 'docker rm -f aria-review-\$CI_JOB_ID'; got: $(cat "$WORK/docker.args")"
pass "after_script removes the job's container"

echo ""
echo "All CI template tests passed."
