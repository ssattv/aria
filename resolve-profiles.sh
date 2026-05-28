#!/usr/bin/env bash
set -euo pipefail

ALL_PERSONAS=(functional architecture security performance readability)

if [[ -z "${ARIA_PROFILES:-}" ]]; then
  echo "${ALL_PERSONAS[*]}"
  exit 0
fi

PERSONAS=()
IFS=',' read -ra _requested <<< "$ARIA_PROFILES"
for _p in "${_requested[@]}"; do
  _p="${_p// /}"
  if [[ " ${ALL_PERSONAS[*]} " == *" $_p "* ]]; then
    PERSONAS+=("$_p")
  else
    echo "WARNING: Unknown profile '$_p' — skipping" >&2
  fi
done

if [[ ${#PERSONAS[@]} -eq 0 ]]; then
  echo "ERROR: ARIA_PROFILES='$ARIA_PROFILES' produced no valid profiles. Known: ${ALL_PERSONAS[*]}" >&2
  exit 1
fi

echo "${PERSONAS[*]}"
