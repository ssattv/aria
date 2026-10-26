#!/bin/bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "Usage: $0 <output-file>" >&2; exit 1; }
OUTPUT_FILE="$1"

: "${FEATURE_BRANCH:?FEATURE_BRANCH is not set}"
: "${TARGET_BRANCH:?TARGET_BRANCH is not set}"
: "${CHANGED_FILES:?CHANGED_FILES is not set}"

if [[ ! -f "$CHANGED_FILES" ]]; then
  echo "Error: CHANGED_FILES '$CHANGED_FILES' does not exist" >&2
  exit 1
fi

git rev-parse --verify "$FEATURE_BRANCH" > /dev/null 2>&1 \
  || { echo "Error: branch '$FEATURE_BRANCH' does not exist" >&2; exit 1; }
git rev-parse --verify "$TARGET_BRANCH" > /dev/null 2>&1 \
  || { echo "Error: branch '$TARGET_BRANCH' does not exist" >&2; exit 1; }

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read -ra PERSONAS <<< "$("$SCRIPT_DIR/resolve-profiles.sh")"
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

log "Reviewing '${FEATURE_BRANCH}' against '${TARGET_BRANCH}'"
log "Changed files: $(wc -l < "$CHANGED_FILES") file(s)"
log "Personas: ${PERSONAS[*]}"

declare -A PERSONA_FOCUS
PERSONA_FOCUS[functional]="Focus ONLY on: logic bugs, off-by-one errors, null/undefined handling, missing error paths, incorrect algorithm behavior, unhandled edge cases. Ignore style, architecture, and performance unless they directly cause bugs.
# Navigate codebase first to understand purpose of the changes and based on the understanding review all impacted files."
PERSONA_FOCUS[architecture]="Focus ONLY on: SRP violations, tight coupling, abstraction leaks, wrong dependency direction, methods longer than 10 lines, classes with too many responsibilities, SOLID/KISS/DRY violations. Ignore syntax and runtime bugs. Navigate codebase if needed to understand larger picture."
PERSONA_FOCUS[security]="Focus ONLY on: injection risks, missing input validation, authentication/authorization gaps, sensitive data exposure, hardcoded secrets, unsafe deserialization, trust boundary violations. Ignore style and non-security architecture."
PERSONA_FOCUS[performance]="Focus ONLY on: algorithmic complexity, N+1 queries, unnecessary allocations, blocking I/O in async contexts, redundant computation, missing caching opportunities. Ignore style and correctness unless they directly cause performance issues."
PERSONA_FOCUS[readability]="Focus ONLY on: misleading or unclear names, deeply nested or high-cognitive-load logic, dead code and commented-out blocks, magic numbers and strings that should be named constants, missing comments on genuinely non-obvious behavior, leftover debug/print statements (print(), console.log(), System.out.println(), fmt.Println(), debugger, dd(), var_dump(), or equivalent). Ignore correctness, architecture, and performance."

log "Reviewing personas sequentially..."
for persona in "${PERSONAS[@]}"; do
  (
    PROMPT="You are a code reviewer. ${PERSONA_FOCUS[$persona]}

Review branch '${FEATURE_BRANCH}' against '${TARGET_BRANCH}'.
Changed files are listed in '${CHANGED_FILES}'.
Only explore listed files against the target branch; navigate the codebase autonomously if needed but ONLY comment on files listed in '${CHANGED_FILES}'.

Print all files you are going to review before starting.

To get the diff for a specific file, ONLY use:
  git diff \$(git merge-base ${TARGET_BRANCH} HEAD) -- <FILE_TO_REVIEW>

Output ONLY a raw JSON object — no prose, no markdown fences:
{\"comments\": [{\"file\": \"<path>\", \"line\": <n>, \"severity\": \"CRITICAL|BUG|WARNING|SUGGEST\", \"persona\": \"${persona}\", \"comment\": \"<text>\"}]}"

    log "  [${persona}] started"
    opencode_exit=0
    timeout 600 opencode run "$PROMPT" --agent "review_${persona}" \
      < /dev/null \
      > "$TMPDIR_WORK/${persona}.raw" \
      2> >(tee "$TMPDIR_WORK/${persona}.err" >&2) || opencode_exit=$?

    # A failed persona leaves a .failed marker, so the merge step can report it
    # instead of treating it as "no findings"
    if [[ $opencode_exit -eq 124 ]]; then
      log "  [${persona}] TIMED OUT after 10 min — likely hit token limit"
      echo '{"comments":[]}' > "$TMPDIR_WORK/${persona}.json"
      touch "$TMPDIR_WORK/${persona}.failed"
      exit 0
    fi

    if [[ $opencode_exit -ne 0 ]]; then
      log "  [${persona}] FAILED (exit ${opencode_exit})"
      [[ -s "$TMPDIR_WORK/${persona}.err" ]] && \
        sed "s/^/    [${persona}] /" "$TMPDIR_WORK/${persona}.err" >&2
      echo '{"comments":[]}' > "$TMPDIR_WORK/${persona}.json"
      touch "$TMPDIR_WORK/${persona}.failed"
      exit 0
    fi

    if ! python3 - "$TMPDIR_WORK/${persona}.raw" > "$TMPDIR_WORK/${persona}.json" 2>/dev/null <<'PYEOF'
import sys, json, re

text = open(sys.argv[1]).read()

# Strategy 1: markdown fences ```json ... ```
for m in re.finditer(r'```(?:json)?\s*\n?(.*?)\n?```', text, re.DOTALL):
    candidate = m.group(1).strip()
    try:
        obj = json.loads(candidate)
        if 'comments' in obj:
            print(json.dumps(obj))
            sys.exit(0)
    except json.JSONDecodeError:
        pass

# Strategy 2: entire raw output as JSON
try:
    obj = json.loads(text.strip())
    if 'comments' in obj:
        print(json.dumps(obj))
        sys.exit(0)
except json.JSONDecodeError:
    pass

# Strategy 3: raw_decode — string-aware scan from each {
decoder = json.JSONDecoder()
for i, ch in enumerate(text):
    if ch == '{':
        try:
            obj, _ = decoder.raw_decode(text, i)
            if 'comments' in obj:
                print(json.dumps(obj))
                sys.exit(0)
        except json.JSONDecodeError:
            continue

sys.exit(1)
PYEOF
    then
      log "  [${persona}] FAILED — no JSON object with 'comments' in the output"
      echo '{"comments":[]}' > "$TMPDIR_WORK/${persona}.json"
      touch "$TMPDIR_WORK/${persona}.failed"
      exit 0
    fi

    count=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('comments', [])))" \
      "$TMPDIR_WORK/${persona}.json" 2>/dev/null || echo "?")
    log "  [${persona}] done — ${count} finding(s)"
  )
done

log "All personas complete"

# Merge all persona outputs into a single comments array
log "Merging results..."
persona_files=()
failed_personas=()
for persona in "${PERSONAS[@]}"; do
  persona_files+=("$TMPDIR_WORK/${persona}.json")
  [[ -f "$TMPDIR_WORK/${persona}.failed" ]] && failed_personas+=("$persona")
done
jq -s '{comments: [.[].comments[] | select(.comment != null)], failed_personas: $ARGS.positional}' \
  "${persona_files[@]}" --args "${failed_personas[@]}" > "$OUTPUT_FILE"
log "Results written to '${OUTPUT_FILE}'"

total=$(jq -s '[.[].comments[]] | length' "${persona_files[@]}")
log "Done — ${total} total finding(s)"

if [[ ${#failed_personas[@]} -gt 0 ]]; then
  log "ERROR: ${#failed_personas[@]} reviewer(s) failed: ${failed_personas[*]}"
  exit 1
fi
