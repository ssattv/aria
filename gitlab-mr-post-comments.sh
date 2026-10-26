#!/usr/bin/env bash
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

[[ $# -eq 3 ]] || die "usage: $0 <PROJECT_ID> <MR_IID> <comments.json>"

PROJECT_ID="$1"
MR_IID="$2"
COMMENTS_FILE="$3"

: "${GITLAB_URL:?GITLAB_URL is not set}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is not set}"

API="${GITLAB_URL%/}/api/v4/projects/${PROJECT_ID}/merge_requests/${MR_IID}"

post_note() {
  local body="$1"
  local http_code
  http_code=$(curl -sS -k -o /dev/null -w '%{http_code}' -X POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$(jq -n --arg body "$body" '{body: $body}')" \
    "${API}/notes") || true
  [[ "$http_code" == "201" ]] || log "note POST returned HTTP ${http_code}"
}

# Step 0: validate comments.json
if ! jq empty "$COMMENTS_FILE" 2>/dev/null; then
  log "comments.json is invalid or empty"
  post_note "⚠️ **AI Review**: produced no parseable output — check CI job log for details"
  exit 0
fi

failed_personas=$(jq -r '(.failed_personas // []) | join(", ")' "$COMMENTS_FILE")
post_failed_note() {
  log "Reviewer(s) failed: ${failed_personas}"
  post_note "❌ **AI Review did not complete**: reviewer(s) failed: ${failed_personas}. $1 Check the CI job log for the error."
}

comment_count=$(jq '.comments | length' "$COMMENTS_FILE" 2>/dev/null || echo 0)
if [[ "$comment_count" -eq 0 && -n "$failed_personas" ]]; then
  post_failed_note "No review was done for them."
  exit 0
fi
if [[ "$comment_count" -eq 0 ]]; then
  log "No findings — posting clean result"
  post_note "✅ **AI Review**: found no issues in this MR"
  exit 0
fi

log "Processing ${comment_count} comment(s)"

# Step 1: fetch diff_refs
mr_info=$(curl -sS -k \
  --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${API}")

base_sha=$(jq -r '.diff_refs.base_sha' <<< "$mr_info")
head_sha=$(jq -r '.diff_refs.head_sha' <<< "$mr_info")
start_sha=$(jq -r '.diff_refs.start_sha' <<< "$mr_info")

[[ "$base_sha" != "null" && -n "$base_sha" ]] || die "failed to fetch diff_refs from GitLab API (base_sha is null — check GITLAB_URL, GITLAB_TOKEN, and network)"

log "diff_refs: base=${base_sha:0:8} head=${head_sha:0:8} start=${start_sha:0:8}"

# Step 2: post inline discussions
failed_comments=()

while IFS= read -r comment; do
  file=$(jq -r '.file'    <<< "$comment")
  line=$(jq -r '.line'    <<< "$comment")
  severity=$(jq -r '.severity' <<< "$comment")
  persona=$(jq -r '.persona'  <<< "$comment")
  text=$(jq -r '.comment'   <<< "$comment")

  body="**[${severity}]** \`${persona}\` — ${text}"

  payload=$(jq -n \
    --arg  body       "$body"      \
    --arg  base_sha   "$base_sha"  \
    --arg  head_sha   "$head_sha"  \
    --arg  start_sha  "$start_sha" \
    --arg  new_path   "$file"      \
    --argjson new_line "$line"     \
    '{
      body: $body,
      position: {
        position_type: "text",
        base_sha:      $base_sha,
        head_sha:      $head_sha,
        start_sha:     $start_sha,
        new_path:      $new_path,
        new_line:      $new_line
      }
    }')

  http_code=$(curl -sS -k -o /dev/null -w '%{http_code}' \
    -X POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$payload" \
    "${API}/discussions")

  if [[ "$http_code" == "201" ]]; then
    log "  inline ok: ${file}:${line} [${severity}]"
  else
    log "  inline failed (HTTP ${http_code}): ${file}:${line} — queued for summary"
    failed_comments+=("$comment")
  fi
done < <(jq -c '.comments[]' "$COMMENTS_FILE")

# Step 3: fallback summary note for failed positions
if [[ ${#failed_comments[@]} -gt 0 ]]; then
  log "Posting summary note for ${#failed_comments[@]} comment(s)"

  nl=$'\n'
  summary="## AI Review — Findings${nl}${nl}_These comments could not be placed inline (line not in diff):_${nl}${nl}"

  for severity in CRITICAL BUG WARNING SUGGEST; do
    section=""
    for c in "${failed_comments[@]}"; do
      [[ "$(jq -r '.severity' <<< "$c")" == "$severity" ]] || continue
      f=$(jq -r '.file'    <<< "$c")
      l=$(jq -r '.line'    <<< "$c")
      p=$(jq -r '.persona' <<< "$c")
      t=$(jq -r '.comment' <<< "$c")
      section+="- **${f}:${l}** \`${p}\` — ${t}${nl}"
    done
    if [[ -n "$section" ]]; then summary+="### ${severity}${nl}${section}${nl}"; fi
  done

  post_note "$summary"
fi

if [[ -n "$failed_personas" ]]; then
  post_failed_note "Findings from the other reviewers are posted above."
fi

log "Done"
