#!/usr/bin/env bash
# Load env from secrets (if exist) or from section-formatted repo.env (multi-line safe)
set -e

ENV_FILE="${1:-repo.env}"

declare -A SECTION_VARS
section=""
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^# ]] && continue
  if [[ "$line" =~ ^\[([A-Z0-9_]+)\]$ ]]; then
    section="${BASH_REMATCH[1]}"
    SECTION_VARS["$section"]=""
    continue
  fi
  if [[ -n "$section" ]]; then
    [[ -z "$line" ]] && continue
    if [[ -n "${SECTION_VARS[$section]}" ]]; then
      SECTION_VARS["$section"]+=$'\n'"$line"
    else
      SECTION_VARS["$section"]="$line"
    fi
    continue
  fi
done < "$ENV_FILE"

for k in "${!SECTION_VARS[@]}"; do
  v="${SECTION_VARS[$k]}"
  v="$(echo "$v" | sed '/^[[:space:]]*$/d')"
  if [[ -z "${!k}" ]]; then
    export "$k"="$v"
    echo "$k<<EOF" >> $GITHUB_ENV
    echo "$v" >> $GITHUB_ENV
    echo "EOF" >> $GITHUB_ENV
  fi
done