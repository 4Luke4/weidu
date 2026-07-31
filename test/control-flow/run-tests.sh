#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
weidu=${1:-"$repo_root/weidu"}

if [[ ! -x "$weidu" ]]; then
  echo "WeiDU executable not found or not executable: $weidu" >&2
  exit 2
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cp "$script_dir/control-flow.tp2" "$work_dir/setup-control-flow.tp2"
(
  cd "$work_dir"
  if ! "$weidu" --nogame --yes --force-install 0 --no-exit-pause \
      setup-control-flow.tp2 >runtime.log 2>&1; then
    cat runtime.log >&2
    exit 1
  fi
  if ! grep -Fq "TP2 control-flow regression tests passed" runtime.log; then
    cat runtime.log >&2
    echo "Control-flow runtime test did not complete successfully." >&2
    exit 1
  fi
)

check_invalid() {
  local kind=$1
  local fixture=$2
  local expected=$3
  local output="$work_dir/$(basename "$fixture").log"

  if "$weidu" --nogame --parse-check "$kind" "$fixture" >"$output" 2>&1; then
    cat "$output" >&2
    echo "Expected $kind parse failure: $fixture" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$output"; then
    cat "$output" >&2
    echo "Parse failure did not report the expected validation: $expected" >&2
    exit 1
  fi
}

check_invalid TPA "$script_dir/invalid/action-break-outside-loop.tpa" \
  "Action BREAK is not inside an action loop"
check_invalid TPA "$script_dir/invalid/action-duplicate-label.tpa" \
  "Duplicate action control-flow label"
check_invalid TPA "$script_dir/invalid/action-function-escape.tpa" \
  "Action GOTO has no visible label"
check_invalid TPA "$script_dir/invalid/action-jump-into-block.tpa" \
  "Action GOTO has no visible label"
check_invalid TPA "$script_dir/invalid/action-unknown-label.tpa" \
  "Action GOTO has no visible label"
check_invalid TPP "$script_dir/invalid/patch-break-outside-loop.tpp" \
  "Patch BREAK is not inside a patch loop"
check_invalid TPP "$script_dir/invalid/patch-buffer-boundary.tpp" \
  "Patch GOTO has no visible label"
check_invalid TPP "$script_dir/invalid/patch-case-sensitive-label.tpp" \
  "Patch GOTO has no visible label"
check_invalid TPP "$script_dir/invalid/patch-duplicate-label.tpp" \
  "Duplicate patch control-flow label"
check_invalid TPP "$script_dir/invalid/patch-unknown-label.tpp" \
  "Patch GOTO has no visible label"

echo "All TP2 control-flow tests passed."
