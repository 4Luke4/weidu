#!/bin/sh

set -eu

weidu_bin=${1:-./weidu}
case "$weidu_bin" in
  /*) ;;
  *) weidu_bin="$(pwd)/$weidu_bin" ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/weidu-control-statements.XXXXXX")

cleanup()
{
  if [ -n "${test_root:-}" ] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT HUP INT TERM

cp "$script_dir"/*.tp2 "$test_root/"
mkdir "$test_root/fixtures"
: >"$test_root/fixtures/alpha.txt"
: >"$test_root/fixtures/beta.txt"

if ! (
  cd "$test_root"
  "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
    control-statements.tp2 </dev/null >valid.log 2>&1
); then
  sed 's/^/| /' "$test_root/valid.log" >&2
  exit 1
fi

if ! grep -F "control-statement tests passed" \
  "$test_root/valid.log" >/dev/null; then
  sed 's/^/| /' "$test_root/valid.log" >&2
  echo "control-statement completion marker was not printed" >&2
  exit 1
fi

expect_rejection()
{
  test_file=$1
  expected=$2
  log_file="$test_root/${test_file%.tp2}.log"

  (
    cd "$test_root"
    "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
      "$test_file" </dev/null >"$log_file" 2>&1
  ) || :

  if ! sed 's/\\"/"/g' "$log_file" | grep -F "$expected" >/dev/null; then
    sed 's/^/| /' "$log_file" >&2
    echo "$test_file did not report: $expected" >&2
    exit 1
  fi
}

expect_rejection invalid-action-break.tp2 \
  "BREAK is not inside an action loop"
expect_rejection invalid-patch-break.tp2 \
  "BREAK is not inside a patch loop"
expect_rejection invalid-undefined-goto.tp2 \
  'GOTO "missing_label" has no visible action label'
expect_rejection invalid-duplicate-label.tp2 \
  'action label "duplicate_label" duplicates a label visible in this block'
expect_rejection invalid-jump-into-block.tp2 \
  'GOTO "nested_label" has no visible action label'
expect_rejection invalid-cross-domain-goto.tp2 \
  'GOTO "action_label" has no visible patch label'
expect_rejection invalid-empty-label.tp2 \
  'an action label requires a non-empty label name'
expect_rejection invalid-macro-goto.tp2 \
  'GOTO "outside_macro" has no visible action label'
expect_rejection invalid-macro-break.tp2 \
  'BREAK is not inside an action loop'

echo "control-statement tests passed"
