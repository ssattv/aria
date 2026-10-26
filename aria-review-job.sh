#!/usr/bin/env bash
# Runs the whole ARIA review for one merge request: config, changed files, review, post.
# Called by both CI templates (ci/aria-review.yml and ci/aria-review-shell.yml) inside the
# ARIA image, from the root of the MR checkout.
set -euo pipefail

: "${CI_PROJECT_DIR:?CI_PROJECT_DIR is not set}"
: "${CI_PROJECT_ID:?CI_PROJECT_ID is not set}"
: "${CI_MERGE_REQUEST_IID:?CI_MERGE_REQUEST_IID is not set}"
: "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:?CI_MERGE_REQUEST_TARGET_BRANCH_NAME is not set}"

OUTPUT=.aria-review/comments.json
TARGET_REF="origin/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"

mkdir -p .aria-review

# Map ARIA_MODEL_API_KEY to the provider-specific env var opencode expects
if [[ -n "${ARIA_MODEL:-}" && -n "${ARIA_MODEL_API_KEY:-}" ]]; then
  provider=$(echo "$ARIA_MODEL" | cut -d'/' -f1 | tr '[:lower:]' '[:upper:]')
  export "${provider}_API_KEY=${ARIA_MODEL_API_KEY}"
fi

# Render opencode.json with the path of this project's checkout
export ARIA_REVIEW_PATH="$CI_PROJECT_DIR"
generate-opencode-config.sh > "$CI_PROJECT_DIR/opencode.json"

# Fetch the list of files changed in this MR
CHANGED_FILES=$(mktemp)
gitlab-mr-changed-files.sh "$CI_PROJECT_ID" "$CI_MERGE_REQUEST_IID" > "$CHANGED_FILES"
export CHANGED_FILES

# MR pipelines fetch only refs/pipelines/<id> (checked out as a detached HEAD), so no
# branch refs exist; review HEAD and fetch the target branch to diff against.
# Skip the fetch if the caller already fetched it (the shell template does, on the host).
git rev-parse --verify --quiet "$TARGET_REF" > /dev/null \
  || git fetch --quiet origin "+refs/heads/${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}:refs/remotes/${TARGET_REF}"
export FEATURE_BRANCH=HEAD
export TARGET_BRANCH="$TARGET_REF"

# Run multi-persona review. If it fails, still post (the MR then says the review did not
# complete), and fail the job afterwards so the pipeline does not show success.
review_exit=0
generate-review-comments.sh "$OUTPUT" || review_exit=$?

gitlab-mr-post-comments.sh "$CI_PROJECT_ID" "$CI_MERGE_REQUEST_IID" "$OUTPUT"

if [[ $review_exit -ne 0 ]]; then
  echo "ERROR: AI review did not complete (exit ${review_exit}); see the reviewer errors above." >&2
  exit "$review_exit"
fi
