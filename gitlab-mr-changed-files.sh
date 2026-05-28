#!/usr/bin/env bash
#
# gitlab-mr-changed-files.sh
# Fetch the list of changed file paths from a GitLab Merge Request
# on a self-hosted GitLab instance.
#
# Usage:
#   ./gitlab-mr-changed-files.sh <PROJECT> <MR_IID>
#
#   PROJECT can be either:
#     - numeric project ID (e.g. 1234)
#     - URL-encoded path (e.g. group%2Fsubgroup%2Frepo)
#     - plain path         (e.g. group/subgroup/repo)   -- will be encoded
#
# Environment:
#   GITLAB_URL    Base URL of the GitLab instance (e.g. https://gitlab.example.com)
#   GITLAB_TOKEN  Personal / Project / CI job token with read_api scope
#
# Options (via env):
#   INCLUDE_OLD=1   Also print old_path for renamed files
#   STATUS=1        Prefix each line with a status letter: A/M/D/R
#   PER_PAGE=100    Page size for the /diffs endpoint (max 100)
#
# Exit codes:
#   0 success, 1 usage error, 2 API error, 3 missing dependency

set -euo pipefail

die()  { printf 'error: %s\n' "$*" >&2; exit "${2:-2}"; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1" 3; }

need curl
need jq

# ---- args & env ----------------------------------------------------------
[[ $# -eq 2 ]] || die "usage: $0 <PROJECT> <MR_IID>" 1

PROJECT_RAW="$1"
MR_IID="$2"

: "${GITLAB_URL:?set GITLAB_URL, e.g. https://gitlab.example.com}"
: "${GITLAB_TOKEN:?set GITLAB_TOKEN (read_api scope)}"

PER_PAGE="${PER_PAGE:-100}"
INCLUDE_OLD="${INCLUDE_OLD:-0}"
STATUS="${STATUS:-0}"

# URL-encode the project path if it isn't numeric and isn't already encoded.
if [[ "$PROJECT_RAW" =~ ^[0-9]+$ ]]; then
  PROJECT="$PROJECT_RAW"
elif [[ "$PROJECT_RAW" == *%2F* ]]; then
  PROJECT="$PROJECT_RAW"
else
  PROJECT="$(jq -rn --arg v "$PROJECT_RAW" '$v|@uri')"
fi

API="${GITLAB_URL%/}/api/v4/projects/${PROJECT}/merge_requests/${MR_IID}/diffs"

# ---- fetch with pagination ----------------------------------------------
page=1
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

: > "$tmp"

while :; do
  http_code=$(
    curl -sS -k -w '%{http_code}' -o "${tmp}.page" \
      --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "${API}?per_page=${PER_PAGE}&page=${page}"
  )

  if [[ "$http_code" != "200" ]]; then
    printf 'API %s returned HTTP %s\n' "$API" "$http_code" >&2
    cat "${tmp}.page" >&2 || true
    exit 2
  fi

  # Stop when GitLab returns an empty array.
  count=$(jq 'length' < "${tmp}.page")
  [[ "$count" -eq 0 ]] && break

  cat "${tmp}.page" >> "$tmp"
  printf '\n' >> "$tmp"

  [[ "$count" -lt "$PER_PAGE" ]] && break
  page=$((page + 1))
done

rm -f "${tmp}.page"

# ---- format output -------------------------------------------------------
# Each page is a JSON array; use `jq -s` to flatten all pages.
#
# Status mapping:
#   A = new_file        D = deleted_file
#   R = renamed_file    M = modified (default)
jq -rs --argjson incOld "$INCLUDE_OLD" --argjson withStatus "$STATUS" '
  add
  | map(
      . as $d
      | (
          if   $d.new_file     then "A"
          elif $d.deleted_file then "D"
          elif $d.renamed_file then "R"
          else "M"
          end
        ) as $s
      | [
          (if $withStatus == 1 then "\($s)\t\($d.new_path)" else $d.new_path end),
          (if $incOld == 1 and $d.renamed_file
             then (if $withStatus == 1 then "R_old\t\($d.old_path)" else $d.old_path end)
             else empty
           end)
        ]
    )
  | flatten
  | unique
  | .[]
' "$tmp"