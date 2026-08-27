#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
weidu_bin=${1:-"$repo_root/weidu"}

case "$weidu_bin" in
  /*) ;;
  *) weidu_bin=$(cd -- "$(dirname -- "$weidu_bin")" && pwd)/$(basename -- "$weidu_bin") ;;
esac

if [[ ! -x "$weidu_bin" ]]; then
  printf '%s\n' "WeiDU executable not found or not executable: $weidu_bin" >&2
  exit 2
fi

for command in cp find sha256sum sort xargs /usr/bin/time; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf '%s\n' "Required benchmark command not found: $command" >&2
    exit 2
  fi
done

counts=${BENCH_COUNTS:-"1000 10000 100000"}
repetition_override=${BENCH_REPETITIONS:-}
jobs=${BENCH_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}
case "$jobs" in
  ''|*[!0-9]*|0) printf '%s\n' "BENCH_JOBS must be a positive integer: $jobs" >&2; exit 2 ;;
esac

previous_count=0
for count in $counts; do
  case "$count" in
    ''|*[!0-9]*|0) printf '%s\n' "BENCH_COUNTS contains an invalid value: $count" >&2; exit 2 ;;
  esac
  if (( count <= previous_count )); then
    printf '%s\n' 'BENCH_COUNTS must be a strictly increasing list.' >&2
    exit 2
  fi
  previous_count=$count
done

if [[ -n "$repetition_override" ]]; then
  case "$repetition_override" in
    *[!0-9]*|0) printf '%s\n' "BENCH_REPETITIONS must be a positive integer: $repetition_override" >&2; exit 2 ;;
  esac
fi

if [[ -n ${BENCH_RESULT_DIR:-} ]]; then
  result_dir=$BENCH_RESULT_DIR
  if [[ -e "$result_dir" ]] && [[ -n $(find "$result_dir" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    printf '%s\n' "BENCH_RESULT_DIR is not empty: $result_dir" >&2
    exit 2
  fi
  mkdir -p -- "$result_dir"
else
  result_dir=$(mktemp -d "${TMPDIR:-/tmp}/weidu-structured-benchmark-results.XXXXXX")
fi
result_dir=$(cd -- "$result_dir" && pwd)

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/weidu-structured-benchmark.XXXXXX")
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p \
  "$work_dir/override" \
  "$work_dir/benchmark-input" \
  "$work_dir/benchmark-out-field-structured" \
  "$work_dir/benchmark-out-field-direct" \
  "$work_dir/benchmark-out-field-bundled" \
  "$work_dir/benchmark-out-structural-structured" \
  "$work_dir/benchmark-out-structural-direct"
cp -- "$script_dir/benchmark.tp2" "$work_dir/benchmark.tp2"

run_weidu() {
  local component=$1
  local log_file=$2
  (
    cd -- "$work_dir"
    rm -f -- weidu.log BENCHMARK.DEBUG benchmark.debug \
      SETUP-BENCHMARK.DEBUG setup-benchmark.debug
    "$weidu_bin" --nogame --no-exit-pause --force-install "$component" \
      benchmark.tp2 </dev/null >"$log_file" 2>&1
  )
}

if ! run_weidu 0 seed.log; then
  printf '%s\n' 'Unable to generate the benchmark seed. Full log:' >&2
  sed -n '1,240p' "$work_dir/seed.log" >&2
  exit 1
fi
seed="$work_dir/override/bseed.itm"
if [[ ! -s "$seed" ]]; then
  printf '%s\n' 'Benchmark seed is missing or empty.' >&2
  sed -n '1,240p' "$work_dir/seed.log" >&2
  exit 1
fi

raw="$result_dir/raw.tsv"
printf 'workload\tmethod\tfiles\trepetition\twall_seconds\tuser_seconds\tsystem_seconds\tmax_rss_kib\tpatch_user_seconds\n' >"$raw"

methods=(
  'field|structured|10|benchmark-out-field-structured|bench-field-structured'
  'field|direct|11|benchmark-out-field-direct|bench-field-direct'
  'field|bundled|12|benchmark-out-field-bundled|bench-field-bundled'
  'structural|structured|20|benchmark-out-structural-structured|bench-structural-structured'
  'structural|direct|21|benchmark-out-structural-direct|bench-structural-direct'
)

repetitions_for_count() {
  local count=$1
  if [[ -n "$repetition_override" ]]; then
    printf '%s\n' "$repetition_override"
  elif (( count <= 1000 )); then
    printf '7\n'
  elif (( count <= 10000 )); then
    printf '5\n'
  else
    printf '3\n'
  fi
}

extend_input() {
  local from=$1
  local to=$2
  if (( from > to )); then
    return
  fi
  seq -f 'f%07g.itm' "$from" "$to" |
    xargs -r -n 250 -P "$jobs" sh -c '
      seed=$1
      destination=$2
      shift 2
      for name do
        cp --reflink=never -- "$seed" "$destination/$name"
      done
    ' sh "$seed" "$work_dir/benchmark-input"
}

run_measurement() {
  local specification=$1
  local count=$2
  local repetition=$3
  local workload method component output label
  IFS='|' read -r workload method component output label <<<"$specification"
  local time_file="$work_dir/time.txt"
  local log_file="$work_dir/${workload}-${method}.log"
  local debug_file patch_time wall user system rss

  if ! (
    cd -- "$work_dir"
    rm -f -- weidu.log BENCHMARK.DEBUG benchmark.debug \
      SETUP-BENCHMARK.DEBUG setup-benchmark.debug "$time_file"
    /usr/bin/time -o "$time_file" -f '%e\t%U\t%S\t%M' \
      "$weidu_bin" --nogame --no-exit-pause --force-install "$component" \
      benchmark.tp2 </dev/null >"$log_file" 2>&1
  ); then
    printf '%s\n' "Benchmark failed: $workload/$method at $count files" >&2
    sed -n '1,280p' "$log_file" >&2
    exit 1
  fi

  debug_file=$(find "$work_dir" -maxdepth 1 -type f \
    -iname '*benchmark.debug' -print -quit)
  if [[ -z "$debug_file" ]]; then
    printf '%s\n' "WeiDU debug log missing for $workload/$method" >&2
    exit 1
  fi
  patch_time=$(awk -v label="$label" '$1 == label { value = $NF } END { print value }' "$debug_file")
  if [[ ! "$patch_time" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\n' "PATCH_TIME metric missing for $label" >&2
    sed -n '/Mod Timings/,+12p' "$debug_file" >&2
    exit 1
  fi
  IFS=$'\t' read -r wall user system rss <"$time_file"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$workload" "$method" "$count" "$repetition" \
    "$wall" "$user" "$system" "$rss" "$patch_time" >>"$raw"
}

verify_count() {
  local directory=$1
  local expected=$2
  local actual
  actual=$(find "$work_dir/$directory" -maxdepth 1 -type f -name '*.itm' -printf '.' | wc -c)
  if [[ "$actual" -ne "$expected" ]]; then
    printf '%s\n' "$directory contains $actual files; expected $expected" >&2
    exit 1
  fi
}

write_manifest() {
  local directory=$1
  local destination=$2
  (
    cd -- "$work_dir/$directory"
    find . -maxdepth 1 -type f -name '*.itm' -print0 |
      sort -z |
      xargs -0 sha256sum
  ) >"$destination"
}

verify_outputs() {
  local count=$1
  local directory
  for directory in \
    benchmark-out-field-structured \
    benchmark-out-field-direct \
    benchmark-out-field-bundled \
    benchmark-out-structural-structured \
    benchmark-out-structural-direct
  do
    verify_count "$directory" "$count"
    write_manifest "$directory" "$work_dir/$directory.sha256"
  done
  cmp "$work_dir/benchmark-out-field-structured.sha256" \
      "$work_dir/benchmark-out-field-direct.sha256"
  cmp "$work_dir/benchmark-out-field-structured.sha256" \
      "$work_dir/benchmark-out-field-bundled.sha256"
  cmp "$work_dir/benchmark-out-structural-structured.sha256" \
      "$work_dir/benchmark-out-structural-direct.sha256"
}

current_count=0
for count in $counts; do
  printf 'Preparing %d physical input files...\n' "$count"
  extend_input "$((current_count + 1))" "$count"
  current_count=$count
  repetitions=$(repetitions_for_count "$count")

  printf 'Warming all methods at %d files...\n' "$count"
  for specification in "${methods[@]}"; do
    run_measurement "$specification" "$count" 0
  done
  # Warm-up data exercises the full path but is deliberately excluded.
  awk -F '\t' 'NR == 1 || $4 != 0' "$raw" >"$raw.tmp"
  mv -- "$raw.tmp" "$raw"

  for (( repetition = 1; repetition <= repetitions; ++repetition )); do
    printf 'Measuring %d files, repetition %d/%d...\n' \
      "$count" "$repetition" "$repetitions"
    if (( repetition % 2 == 1 )); then
      for specification in "${methods[@]}"; do
        run_measurement "$specification" "$count" "$repetition"
      done
    else
      for (( index = ${#methods[@]} - 1; index >= 0; --index )); do
        run_measurement "${methods[index]}" "$count" "$repetition"
      done
    fi
  done
  verify_outputs "$count"
done

metric_values() {
  local workload=$1 method=$2 count=$3 column=$4
  awk -F '\t' -v workload="$workload" -v method="$method" \
    -v count="$count" -v column="$column" \
    'NR > 1 && $1 == workload && $2 == method && $3 == count { print $column }' \
    "$raw" | sort -n
}

median_metric() {
  local workload=$1 method=$2 count=$3 column=$4
  local values=()
  mapfile -t values < <(metric_values "$workload" "$method" "$count" "$column")
  local length=${#values[@]}
  if (( length == 0 )); then
    printf '%s\n' 'missing'
  elif (( length % 2 == 1 )); then
    printf '%s\n' "${values[length / 2]}"
  else
    awk -v a="${values[length / 2 - 1]}" -v b="${values[length / 2]}" \
      'BEGIN { printf "%.3f\n", (a + b) / 2 }'
  fi
}

summary="$result_dir/summary.md"
{
  printf '# Structured resource benchmark\n\n'
  printf 'All rows report medians from measured runs after one warm-up. '
  printf 'The wall-time ratio is relative to the purpose-built direct-offset function for the same workload and scale.\n\n'
  printf '| Workload | Files | Method | Runs | Median wall (s) | Wall range (s) | Median PATCH_TIME (CPU s) | Files/s | Wall ratio vs direct |\n'
  printf '|---|---:|---|---:|---:|---:|---:|---:|---:|\n'
  for count in $counts; do
    repetitions=$(repetitions_for_count "$count")
    for workload in field structural; do
      direct_wall=$(median_metric "$workload" direct "$count" 5)
      if [[ "$workload" == field ]]; then
        report_methods=(structured direct bundled)
      else
        report_methods=(structured direct)
      fi
      for method in "${report_methods[@]}"; do
        wall=$(median_metric "$workload" "$method" "$count" 5)
        patch=$(median_metric "$workload" "$method" "$count" 9)
        mapfile -t wall_values < <(metric_values "$workload" "$method" "$count" 5)
        minimum=${wall_values[0]}
        maximum=${wall_values[${#wall_values[@]}-1]}
        throughput=$(awk -v files="$count" -v seconds="$wall" \
          'BEGIN { if (seconds == 0) print "inf"; else printf "%.1f", files / seconds }')
        ratio=$(awk -v measured="$wall" -v baseline="$direct_wall" \
          'BEGIN { if (baseline == 0) print "n/a"; else printf "%.3f", measured / baseline }')
        printf '| %s | %s | %s | %s | %s | %s-%s | %s | %s | %s |\n' \
          "$workload" "$count" "$method" "$repetitions" "$wall" \
          "$minimum" "$maximum" "$patch" "$throughput" "$ratio"
      done
    done
  done
} >"$summary"

environment="$result_dir/environment.txt"
{
  printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'uname=%s\n' "$(uname -a)"
  printf 'cpu=%s\n' "$(awk -F ': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)"
  printf 'logical_cpus=%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  printf 'memory_kib=%s\n' "$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)"
  printf 'weidu_binary=%s\n' "$weidu_bin"
  printf 'weidu_sha256=%s\n' "$(sha256sum "$weidu_bin" | awk '{ print $1 }')"
  printf 'git_head=%s\n' "$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  printf 'counts=%s\n' "$counts"
  printf 'repetition_override=%s\n' "${repetition_override:-adaptive_7_5_3}"
  printf 'generation_jobs=%s\n' "$jobs"
} >"$environment"

printf '\nResults: %s\n' "$result_dir"
sed -n '1,80p' "$summary"
