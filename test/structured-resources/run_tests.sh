#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
weidu_bin=${1:-"$repo_root/weidu"}

case "$weidu_bin" in
  /*) ;;
  *) weidu_bin=$(CDPATH= cd -- "$(dirname -- "$weidu_bin")" && pwd)/$(basename -- "$weidu_bin") ;;
esac

if [ ! -x "$weidu_bin" ]; then
  printf '%s\n' "WeiDU executable not found or not executable: $weidu_bin" >&2
  exit 2
fi

test_dir=$(mktemp -d "${TMPDIR:-/tmp}/weidu-structured-resources.XXXXXX")
cleanup() {
  rm -rf -- "$test_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$test_dir/structured-resources" "$test_dir/override"
cp "$script_dir/structured-resources.tp2" "$test_dir/structured-resources.tp2"
cp "$script_dir/verify.sh" "$test_dir/structured-resources/verify.sh"
chmod +x "$test_dir/structured-resources/verify.sh"

(
  cd "$test_dir"
  "$weidu_bin" --nogame --no-exit-pause --force-install 0 \
    structured-resources.tp2 </dev/null >test.log 2>&1
)

if ! grep -q 'STRUCTURED_RESOURCE_TESTS_OK' "$test_dir/test.log"; then
  printf '%s\n' 'Structured resource test marker missing. Full WeiDU log:' >&2
  sed -n '1,240p' "$test_dir/test.log" >&2
  exit 1
fi

cmp "$test_dir/override/s_equiv.itm" "$test_dir/override/l_equiv.itm"

printf '%s\n' 'Structured resource regression tests passed.'
