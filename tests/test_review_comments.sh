#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../generate-review-comments.sh"
CI_TEMPLATE="$SCRIPT_DIR/../ci/aria-review.yml"
JOB_SCRIPT="$SCRIPT_DIR/../aria-review-job.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Stub opencode so no model is called
mkdir -p "$WORK/bin"
cat > "$WORK/bin/opencode" <<'EOF'
#!/usr/bin/env bash
echo '{"comments":[{"file":"a.txt","line":1,"severity":"BUG","persona":"functional","comment":"stub finding"}]}'
EOF
chmod +x "$WORK/bin/opencode"

# Throwaway repo with a feature branch off main
mkdir -p "$WORK/repo"
cd "$WORK/repo"
git init -q -b main
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git checkout -q -b feature
echo hi > a.txt
git add a.txt
git -c user.email=t@t -c user.name=t commit -q -m feature
echo a.txt > "$WORK/changed.txt"

export PATH="$WORK/bin:$PATH"
export FEATURE_BRANCH=feature TARGET_BRANCH=main CHANGED_FILES="$WORK/changed.txt" ARIA_PROFILES=functional

# Test 1: runs in a checkout with no pre-existing ./tmp and writes merged output
"$SCRIPT" "$WORK/out.json" 2>/dev/null || fail "script exited non-zero in a clean checkout"
[[ "$(jq -r '.comments[0].comment' "$WORK/out.json")" == "stub finding" ]] \
  || fail "expected stub finding in output, got: $(cat "$WORK/out.json")"
[[ ! -e ./tmp ]] || fail "script left a ./tmp directory in the reviewed checkout"
pass "writes merged comments without needing ./tmp in the checkout"

# Test 2: the CI job passes the output path as an argument (script does not write JSON to stdout)
grep -qE '^\s*generate-review-comments\.sh "\$OUTPUT"' "$JOB_SCRIPT" \
  && grep -qE '^OUTPUT=\.aria-review/comments\.json$' "$JOB_SCRIPT" \
  || fail "aria-review-job.sh must call 'generate-review-comments.sh \"\$OUTPUT\"' with OUTPUT=.aria-review/comments.json"
pass "CI job passes output path as an argument"

# Test 3: CI job script works in a merge-request pipeline checkout.
# MR pipelines fetch only +refs/pipelines/<id> and check it out detached, so neither the
# source nor the target branch exists as a ref until the job fetches it.
mkdir -p "$WORK/ci" "$WORK/cibin"
cd "$WORK/ci"
git init -q
git remote add origin "$WORK/repo"
git fetch -q origin +refs/heads/feature:refs/pipelines/42
git checkout -q --detach refs/pipelines/42

# Stub the GitLab API scripts; generate-review-comments.sh runs for real
cat > "$WORK/cibin/generate-opencode-config.sh" <<'EOF'
#!/usr/bin/env bash
echo '{}'
EOF
cat > "$WORK/cibin/gitlab-mr-changed-files.sh" <<'EOF'
#!/usr/bin/env bash
echo a.txt
EOF
cat > "$WORK/cibin/gitlab-mr-post-comments.sh" <<EOF
#!/usr/bin/env bash
cp "\$3" "$WORK/posted.json"
EOF
chmod +x "$WORK/cibin"/*.sh

job_script=$(python3 -c "
import sys, yaml
print('\n'.join(yaml.safe_load(open(sys.argv[1]))['ai_code_review']['script']))
" "$CI_TEMPLATE") || fail "could not read ai_code_review.script from ci/aria-review.yml (needs python3 + pyyaml)"

unset FEATURE_BRANCH TARGET_BRANCH CHANGED_FILES
PATH="$WORK/cibin:$SCRIPT_DIR/..:$PATH" \
  CI_PROJECT_DIR="$WORK/ci" CI_PROJECT_ID=1 CI_MERGE_REQUEST_IID=7 \
  CI_MERGE_REQUEST_SOURCE_BRANCH_NAME=feature CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main \
  bash -eo pipefail -c "$job_script" 2>"$WORK/job.err" \
  || fail "CI job script exited non-zero in an MR pipeline checkout: $(tail -3 "$WORK/job.err")"
[[ "$(jq -r '.comments[0].comment' "$WORK/posted.json" 2>/dev/null)" == "stub finding" ]] \
  || fail "expected stub finding to reach the post step, got: $(cat "$WORK/posted.json" 2>/dev/null || echo '<nothing posted>')"
pass "CI job reviews and posts in an MR pipeline checkout (only refs/pipelines/<id> fetched)"

# Test 4: the job does not fetch the target branch again when it is already there.
# The shell-runner template fetches it on the host, where the runner's git credentials
# work; inside the container a second fetch would fail.
rm -f "$WORK/posted.json"
git remote set-url origin "$WORK/no-such-remote"
PATH="$WORK/cibin:$SCRIPT_DIR/..:$PATH" \
  CI_PROJECT_DIR="$WORK/ci" CI_PROJECT_ID=1 CI_MERGE_REQUEST_IID=7 \
  CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main \
  "$JOB_SCRIPT" 2>"$WORK/job.err" \
  || fail "job tried to fetch an already-present target branch: $(tail -3 "$WORK/job.err")"
[[ -s "$WORK/posted.json" ]] || fail "expected comments to be posted when the target branch was pre-fetched"
pass "skips the target-branch fetch when origin/<target> already exists"

# Stubs for a reviewer that crashes (like a 401 from the model API) and one that prints junk
mkdir -p "$WORK/failbin" "$WORK/junkbin"
cat > "$WORK/failbin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "Error: Failed to get direct access token: 401 Unauthorized" >&2
exit 1
EOF
cat > "$WORK/junkbin/opencode" <<'EOF'
#!/usr/bin/env bash
echo "I could not finish the review."
EOF
chmod +x "$WORK/failbin/opencode" "$WORK/junkbin/opencode"

# Test 5: a crashed reviewer is recorded in failed_personas and the script exits non-zero
rc=0
PATH="$WORK/failbin:$PATH" FEATURE_BRANCH=HEAD TARGET_BRANCH=origin/main CHANGED_FILES="$WORK/changed.txt" \
  ARIA_PROFILES=functional "$SCRIPT" "$WORK/failed.json" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] || fail "expected non-zero exit when a reviewer crashes"
[[ "$(jq -c '.failed_personas' "$WORK/failed.json")" == '["functional"]' ]] \
  || fail "expected failed_personas [\"functional\"], got: $(cat "$WORK/failed.json")"
pass "crashed reviewer is listed in failed_personas and the script exits non-zero"

# Test 6: a reviewer whose output has no JSON counts as failed, not as "no findings"
rc=0
PATH="$WORK/junkbin:$PATH" FEATURE_BRANCH=HEAD TARGET_BRANCH=origin/main CHANGED_FILES="$WORK/changed.txt" \
  ARIA_PROFILES=functional "$SCRIPT" "$WORK/junk.json" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] || fail "expected non-zero exit when a reviewer prints no JSON"
[[ "$(jq -c '.failed_personas' "$WORK/junk.json")" == '["functional"]' ]] \
  || fail "expected failed_personas [\"functional\"], got: $(cat "$WORK/junk.json")"
pass "unparseable reviewer output is listed in failed_personas"

# Test 7: when a reviewer fails, the job still posts (so the MR says so) and then fails
rm -f "$WORK/posted.json"
rc=0
PATH="$WORK/failbin:$WORK/cibin:$SCRIPT_DIR/..:$PATH" \
  CI_PROJECT_DIR="$WORK/ci" CI_PROJECT_ID=1 CI_MERGE_REQUEST_IID=7 \
  CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main ARIA_PROFILES=functional \
  "$JOB_SCRIPT" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]] || fail "expected the CI job to fail when a reviewer fails"
[[ "$(jq -c '.failed_personas' "$WORK/posted.json" 2>/dev/null)" == '["functional"]' ]] \
  || fail "expected the post step to run with failed_personas, got: $(cat "$WORK/posted.json" 2>/dev/null || echo '<nothing posted>')"
pass "CI job posts the failure to the MR and then fails"

# Test 8: the changed-files list is inside the checkout.
# opencode.json only allows reading under ARIA_REVIEW_PATH (the checkout); a list in /tmp
# is auto-rejected ("permission requested: external_directory (/tmp/*)").
mkdir -p "$WORK/permbin"
cat > "$WORK/permbin/opencode" <<'EOF'
#!/usr/bin/env bash
# Mimics opencode's external_directory rule: reject the list unless it is under the checkout
path=$(grep -o "listed in '[^']*'" <<< "$2" | head -1 | sed "s/^listed in '//; s/'$//")
case "$path" in
  "$CI_PROJECT_DIR"/*) echo '{"comments":[]}' ;;
  *) echo "permission requested: external_directory ($path); auto-rejecting" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/permbin/opencode"
rm -f "$WORK/posted.json"
PATH="$WORK/permbin:$WORK/cibin:$SCRIPT_DIR/..:$PATH" \
  CI_PROJECT_DIR="$WORK/ci" CI_PROJECT_ID=1 CI_MERGE_REQUEST_IID=7 \
  CI_MERGE_REQUEST_TARGET_BRANCH_NAME=main ARIA_PROFILES=functional \
  "$JOB_SCRIPT" 2>"$WORK/job.err" \
  || fail "reviewer could not read the changed-files list: $(grep -m1 external_directory "$WORK/job.err" || tail -1 "$WORK/job.err")"
pass "changed-files list is inside the checkout, where opencode may read it"

echo ""
echo "All review-comments tests passed."
