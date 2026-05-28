#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/opencode.json.template"

[[ -f "$TEMPLATE" ]] || { echo "error: template not found: $TEMPLATE" >&2; exit 1; }
: "${ARIA_REVIEW_PATH:?ARIA_REVIEW_PATH is not set}"

content=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
print(template.replace('{{ARIA_REVIEW_PATH}}', sys.argv[2]), end='')
" "$TEMPLATE" "$ARIA_REVIEW_PATH")

if [[ -n "${ARIA_MODEL:-}" ]]; then
  content=$(jq --arg model "$ARIA_MODEL" '. + {model: $model}' <<< "$content")
fi

if [[ -n "${ARIA_MODEL_BASE_URL:-}" ]]; then
  content=$(jq --arg url "$ARIA_MODEL_BASE_URL" '. + {provider: {baseURL: $url}}' <<< "$content")
fi

echo "$content"
