#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../gitlab-mr-post-comments.sh"

export GITLAB_URL="https://gitlab.example.com"
export GITLAB_TOKEN="test-token"

MOCK_DIR=$(mktemp -d)
export MOCK_DIR          # must be exported so the mock curl script inherits it
trap 'rm -rf "$MOCK_DIR"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Create a mock curl that records what was called
cat > "$MOCK_DIR/curl" << 'CURL_MOCK'
#!/usr/bin/env bash
ARGS=("$@")
URL="${ARGS[-1]}"
HTTP_CODE_REQUESTED=0
OUTPUT_FILE=""

for i in "${!ARGS[@]}"; do
  [[ "${ARGS[$i]}" == "-w" ]] && HTTP_CODE_REQUESTED=1
  [[ "${ARGS[$i]}" == "-o" ]] && OUTPUT_FILE="${ARGS[$((i+1))]}"
done

if [[ "$URL" == */notes ]]; then
  # Early-exit path: immediate general note (invalid JSON, no findings, or draft fallback)
  for i in "${!ARGS[@]}"; do
    if [[ "${ARGS[$i]}" == "--data" ]]; then
      echo "${ARGS[$((i+1))]}" >> "$MOCK_DIR/notes_posted"
    fi
  done
  [[ "$HTTP_CODE_REQUESTED" == "1" ]] && printf '201' || true
elif [[ "$URL" == */draft_notes/bulk_publish ]]; then
  # Bulk publish all drafts — triggers exactly one notification
  touch "$MOCK_DIR/bulk_published"
  [[ "$HTTP_CODE_REQUESTED" == "1" ]] && printf "${MOCK_BULK_PUBLISH_HTTP_CODE:-200}" || true
elif [[ "$URL" =~ .*/draft_notes/[0-9]+ ]]; then
  # DELETE /draft_notes/:id — cleanup of a specific stale draft
  [[ "$HTTP_CODE_REQUESTED" == "1" ]] && printf "${MOCK_DRAFT_DELETE_HTTP_CODE:-204}" || true
elif [[ "$URL" == */draft_notes ]]; then
  IS_POST=0
  for i in "${!ARGS[@]}"; do
    [[ "${ARGS[$i]}" == "-X" && "${ARGS[$((i+1))]:-}" == "POST" ]] && IS_POST=1
  done
  if [[ "$IS_POST" == "1" ]]; then
    # POST /draft_notes — individual draft note, no notification
    for i in "${!ARGS[@]}"; do
      if [[ "${ARGS[$i]}" == "--data" ]]; then
        echo "${ARGS[$((i+1))]}" >> "$MOCK_DIR/drafts_posted"
      fi
    done
    [[ "$HTTP_CODE_REQUESTED" == "1" ]] && printf "${MOCK_DRAFT_HTTP_CODE:-201}" || true
  else
    # GET /draft_notes — return seeded stale drafts or empty list
    if [[ -f "$MOCK_DIR/existing_drafts" ]]; then
      cat "$MOCK_DIR/existing_drafts"
    else
      printf '[]'
    fi
  fi
elif [[ "$URL" == */discussions ]]; then
  # Kept for backward compatibility; no longer called by the main script
  [[ "$HTTP_CODE_REQUESTED" == "1" ]] && printf "${MOCK_DISCUSSION_HTTP_CODE:-201}" || true
elif [[ "$URL" == */merge_requests/* ]]; then
  # MR info: return diff_refs with correct field names
  printf '{"diff_refs":{"base_sha":"base111","head_sha":"head222","start_sha":"start333"}}'
  [[ "$HTTP_CODE_REQUESTED" == "1" ]] && printf '200' || true
fi
CURL_MOCK
chmod +x "$MOCK_DIR/curl"
export PATH="$MOCK_DIR:$PATH"

# ---- Test 1: invalid JSON posts a failure note ----
printf 'not valid json' > "$MOCK_DIR/bad.json"
> "$MOCK_DIR/notes_posted"
"$SCRIPT" 123 45 "$MOCK_DIR/bad.json"
grep -q "no parseable output" "$MOCK_DIR/notes_posted" \
  || fail "expected 'no parseable output' note for invalid JSON; notes: $(cat "$MOCK_DIR/notes_posted")"
pass "invalid JSON posts failure note to MR"

# ---- Test 2: empty comments array posts a clean note ----
printf '{"comments":[]}' > "$MOCK_DIR/empty.json"
> "$MOCK_DIR/notes_posted"
"$SCRIPT" 123 45 "$MOCK_DIR/empty.json"
grep -q "no issues" "$MOCK_DIR/notes_posted" \
  || fail "expected 'no issues' note for empty comments; notes: $(cat "$MOCK_DIR/notes_posted")"
pass "empty comments array posts 'no issues' note"

# ---- Test 2b: reviewers failed and found nothing → "did not complete" note, never "no issues" ----
printf '{"comments":[],"failed_personas":["functional","security"]}' > "$MOCK_DIR/failed.json"
> "$MOCK_DIR/notes_posted"
"$SCRIPT" 123 45 "$MOCK_DIR/failed.json"
grep -q "did not complete" "$MOCK_DIR/notes_posted" \
  || fail "expected 'did not complete' note when reviewers failed; notes: $(cat "$MOCK_DIR/notes_posted")"
grep -q "functional, security" "$MOCK_DIR/notes_posted" \
  || fail "note must name the failed reviewers; notes: $(cat "$MOCK_DIR/notes_posted")"
grep -q "no issues" "$MOCK_DIR/notes_posted" \
  && fail "must not post 'no issues' when reviewers failed; notes: $(cat "$MOCK_DIR/notes_posted")"
pass "failed reviewers with no findings post 'did not complete', not 'no issues'"

# ---- Test 2c: some reviewers failed, others found issues → findings posted plus a failure note ----
printf '{"comments":[{"file":"a.py","line":1,"severity":"BUG","persona":"functional","comment":"finding A"}],"failed_personas":["security"]}' \
  > "$MOCK_DIR/partial.json"
> "$MOCK_DIR/notes_posted"
"$SCRIPT" 123 45 "$MOCK_DIR/partial.json"
grep -q "did not complete" "$MOCK_DIR/notes_posted" && grep -q "security" "$MOCK_DIR/notes_posted" \
  || fail "expected a note naming the failed reviewer next to the findings; notes: $(cat "$MOCK_DIR/notes_posted")"
pass "partial failure posts findings plus a note naming the failed reviewers"

# ---- Test 3: successful inline draft produces no immediate note; bulk_publish is called ----
printf '{"comments":[{"file":"src/auth.py","line":42,"severity":"CRITICAL","persona":"security","comment":"SQL injection"}]}' \
  > "$MOCK_DIR/one.json"
> "$MOCK_DIR/notes_posted"
> "$MOCK_DIR/drafts_posted"
rm -f "$MOCK_DIR/bulk_published"
"$SCRIPT" 123 45 "$MOCK_DIR/one.json"
[[ ! -s "$MOCK_DIR/notes_posted" ]] \
  || fail "should not post an immediate note when draft succeeds; notes: $(cat "$MOCK_DIR/notes_posted")"
[[ -s "$MOCK_DIR/drafts_posted" ]] \
  || fail "expected at least one draft to be posted"
[[ -f "$MOCK_DIR/bulk_published" ]] \
  || fail "expected bulk_publish to be called after posting drafts"
pass "successful draft post produces no immediate note and triggers bulk_publish"

# ---- Test 4: all drafts fail (HTTP 400) → fallback post_note; bulk_publish NOT called ----
> "$MOCK_DIR/notes_posted"
> "$MOCK_DIR/drafts_posted"
rm -f "$MOCK_DIR/bulk_published"
MOCK_DRAFT_HTTP_CODE=400 "$SCRIPT" 123 45 "$MOCK_DIR/one.json"
[[ -s "$MOCK_DIR/notes_posted" ]] \
  || fail "expected a fallback note when all draft POSTs return 400"
grep -q "src/auth.py" "$MOCK_DIR/notes_posted" \
  || fail "fallback note should contain the file path"
[[ ! -f "$MOCK_DIR/bulk_published" ]] \
  || fail "bulk_publish must not be called when no drafts succeeded"
pass "all-draft HTTP 400: fallback note posted, bulk_publish skipped"

# ---- Test 5: multiple comments all fail, grouped summary in fallback note ----
cat > "$MOCK_DIR/multi.json" << 'EOF'
{"comments":[
  {"file":"a.py","line":1,"severity":"CRITICAL","persona":"security","comment":"finding A"},
  {"file":"b.py","line":2,"severity":"WARNING","persona":"performance","comment":"finding B"}
]}
EOF
> "$MOCK_DIR/notes_posted"
> "$MOCK_DIR/drafts_posted"
rm -f "$MOCK_DIR/bulk_published"
MOCK_DRAFT_HTTP_CODE=400 "$SCRIPT" 123 45 "$MOCK_DIR/multi.json"
grep -q "CRITICAL" "$MOCK_DIR/notes_posted" || fail "summary should contain CRITICAL section"
grep -q "WARNING" "$MOCK_DIR/notes_posted"  || fail "summary should contain WARNING section"
[[ ! -f "$MOCK_DIR/bulk_published" ]] \
  || fail "bulk_publish must not fire when no drafts succeed"
pass "fallback note groups findings by severity; bulk_publish skipped"

# ---- Test 6: multi-comment happy path — all drafts succeed, single bulk_publish ----
> "$MOCK_DIR/drafts_posted"
> "$MOCK_DIR/notes_posted"
rm -f "$MOCK_DIR/bulk_published"
"$SCRIPT" 123 45 "$MOCK_DIR/multi.json"
[[ -s "$MOCK_DIR/drafts_posted" ]] \
  || fail "expected draft notes to be posted for multi-comment success"
grep -q "finding A" "$MOCK_DIR/drafts_posted" \
  || fail "drafts_posted should contain finding A"
grep -q "finding B" "$MOCK_DIR/drafts_posted" \
  || fail "drafts_posted should contain finding B"
[[ -f "$MOCK_DIR/bulk_published" ]] \
  || fail "expected bulk_publish to be called after successful drafts"
[[ ! -s "$MOCK_DIR/notes_posted" ]] \
  || fail "should not post any immediate notes on full draft success"
pass "multi-comment success: all drafts posted, single bulk_publish triggered"

# ---- Test 7: stale drafts from a previous run are deleted before posting new ones ----
printf '[{"id":99,"note":"stale comment from old run"}]' > "$MOCK_DIR/existing_drafts"
> "$MOCK_DIR/drafts_posted"
> "$MOCK_DIR/notes_posted"
rm -f "$MOCK_DIR/bulk_published"
"$SCRIPT" 123 45 "$MOCK_DIR/one.json"
rm -f "$MOCK_DIR/existing_drafts"
[[ -s "$MOCK_DIR/drafts_posted" ]] \
  || fail "expected new draft to be posted after cleanup"
[[ -f "$MOCK_DIR/bulk_published" ]] \
  || fail "expected bulk_publish after stale draft cleanup"
[[ ! -s "$MOCK_DIR/notes_posted" ]] \
  || fail "should not post immediate notes when drafts succeed after cleanup"
pass "stale drafts deleted before posting new ones; no duplicates"

echo ""
echo "All post-comments tests passed."
