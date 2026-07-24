#!/bin/sh

set -eu

weidu_bin=${1:-./weidu}
case "$weidu_bin" in
  /*) ;;
  *) weidu_bin="$(pwd)/$weidu_bin" ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/weidu-command-policy.XXXXXX")

cleanup()
{
  if [ -n "${test_root:-}" ] && [ -d "$test_root" ]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT HUP INT TERM

fail()
{
  echo "external-command-policy test failed: $*" >&2
  exit 1
}

fail_case()
{
  failed_case_dir=$1
  shift
  if [ -f "$failed_case_dir/output.log" ]; then
    echo "----- captured WeiDU output -----" >&2
    sed 's/^/| /' "$failed_case_dir/output.log" >&2
    echo "----- end captured output -----" >&2
  fi
  fail "$@"
}

prepare_case()
{
  case_name=$1
  fixture=$2
  case_dir="$test_root/$case_name"
  mkdir "$case_dir"
  cp "$script_dir/$fixture" "$case_dir/test.tp2"
}

assert_denied()
{
  case_name=$1
  shift
  case_dir="$test_root/$case_name"
  if (
    cd "$case_dir"
    "$weidu_bin" --nogame --no-exit-pause --force-install 0 "$@" \
      test.tp2 </dev/null >output.log 2>&1
  ); then
    fail_case "$case_dir" "$case_name unexpectedly succeeded"
  fi
  [ ! -e "$case_dir/command-ran" ] ||
    fail_case "$case_dir" "$case_name executed the denied command"
  grep -F "External command denied by security policy" \
    "$case_dir/output.log" >/dev/null ||
    fail_case "$case_dir" "$case_name did not report the denial"
}

prepare_case default-deny at-now.tp2
assert_denied default-deny

prepare_case explicit-deny at-now.tp2
assert_denied explicit-deny --deny-external-commands

prepare_case yes-does-not-authorize at-now.tp2
assert_denied yes-does-not-authorize --yes

prepare_case prompt-deny at-now.tp2
case_dir="$test_root/prompt-deny"
if (
  cd "$case_dir"
  printf 'N\n' |
    "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
      --ask-external-commands test.tp2 >output.log 2>&1
); then
  fail_case "$case_dir" "prompt-deny unexpectedly succeeded"
fi
[ ! -e "$case_dir/command-ran" ] ||
  fail_case "$case_dir" "prompt-deny executed the denied command"

prepare_case prompt-allow-once at-now.tp2
case_dir="$test_root/prompt-allow-once"
(
  cd "$case_dir"
  printf 'Y\n' |
    "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
      --ask-external-commands test.tp2 >output.log 2>&1
)
[ -e "$case_dir/command-ran" ] ||
  fail_case "$case_dir" "prompt-allow-once did not execute the authorized command"

prepare_case explicit-allow at-now.tp2
case_dir="$test_root/explicit-allow"
(
  cd "$case_dir"
  "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
    --allow-external-commands test.tp2 </dev/null >output.log 2>&1
)
[ -e "$case_dir/command-ran" ] ||
  fail_case "$case_dir" "explicit-allow did not execute the authorized command"

prepare_case prompt-allow-all at-now-twice.tp2
case_dir="$test_root/prompt-allow-all"
(
  cd "$case_dir"
  printf 'A\n' |
    "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
      --ask-external-commands test.tp2 >output.log 2>&1
)
[ -e "$case_dir/first-command-ran" ] ||
  fail_case "$case_dir" "prompt-allow-all did not execute the first command"
[ -e "$case_dir/second-command-ran" ] ||
  fail_case "$case_dir" "prompt-allow-all did not authorize the rest of the run"

prepare_case deferred-deny at-exit.tp2
assert_denied deferred-deny

prepare_case deferred-allow at-exit.tp2
case_dir="$test_root/deferred-allow"
(
  cd "$case_dir"
  "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
    --allow-external-commands test.tp2 </dev/null >output.log 2>&1
)
[ -e "$case_dir/command-ran" ] ||
  fail_case "$case_dir" "deferred-allow did not execute the authorized command"

echo "external-command-policy tests passed"
