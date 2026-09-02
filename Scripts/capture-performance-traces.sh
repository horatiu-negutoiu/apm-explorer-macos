#!/bin/sh
set -eu

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

internal_test_mode=false
if [ "${1:-}" = --apmx-internal-test-mode ]; then
  [ "${APMX_INTERNAL_SCRIPT_TEST_MODE:-}" = capture-performance-traces ] \
    || fail "Internal capture test mode was not explicitly validated."
  internal_test_mode=true
  shift
fi

test_override_present=false
if [ "${APMX_XCRUN_COMMAND+x}" = x ] \
  || [ "${APMX_CAPTURE_TEST_COUNT_FILE+x}" = x ] \
  || [ "${APMX_CAPTURE_TEST_TIME_LIMIT+x}" = x ] \
  || [ "${APMX_CAPTURE_TEST_FAIL_AT+x}" = x ] \
  || [ "${APMX_CAPTURE_TEST_TARGET_MODE+x}" = x ] \
  || [ "${APMX_CAPTURE_TEST_OTHER_EXECUTABLE+x}" = x ]
then
  test_override_present=true
fi
[ "$test_override_present" = false ] || [ "$internal_test_mode" = true ] \
  || fail "Test overrides require explicit internal capture test mode."

app_path=${1:?usage: capture-performance-traces.sh /path/to/APM Explorer.app output-directory [duration]}
output_directory=${2:?usage: capture-performance-traces.sh /path/to/APM Explorer.app output-directory [duration]}
duration=${3:-30s}
xcrun_command=/usr/bin/xcrun
if [ "$internal_test_mode" = true ] && [ "${APMX_XCRUN_COMMAND+x}" = x ]; then
  xcrun_command=$APMX_XCRUN_COMMAND
fi
toc_parser=/usr/bin/xmllint

[ -x "$xcrun_command" ] || fail "xcrun command is not executable: $xcrun_command"
[ -x "$toc_parser" ] || fail "Required TOC parser is not executable: $toc_parser"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_directory/.." && pwd -P)

[ -d "$app_path" ] || fail "Missing app bundle: $app_path"
app_path_canonical=$(CDPATH= cd -- "$app_path" && pwd -P)
case "$app_path_canonical" in
*.app) ;;
*) fail "App bundle must end in .app: $app_path" ;;
esac

info_plist="$app_path_canonical/Contents/Info.plist"
[ -f "$info_plist" ] || fail "Missing app Info.plist: $info_plist"
bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null) \
  || fail "Missing CFBundleExecutable in: $info_plist"
case "$bundle_executable" in
'' | */*) fail "Invalid CFBundleExecutable in: $info_plist" ;;
esac
app_executable="$app_path_canonical/Contents/MacOS/$bundle_executable"
[ -f "$app_executable" ] && [ -x "$app_executable" ] \
  || fail "Missing executable in app bundle: $app_executable"

[ ! -e "$output_directory" ] || fail "Output path already exists: $output_directory"
output_parent=$(dirname -- "$output_directory")
output_leaf=$(basename -- "$output_directory")
[ -d "$output_parent" ] || fail "Output parent does not exist: $output_parent"
case "$output_leaf" in
'' | . | ..) fail "Invalid output directory: $output_directory" ;;
esac
output_parent_canonical=$(CDPATH= cd -- "$output_parent" && pwd -P)
output_path_canonical="$output_parent_canonical/$output_leaf"
case "$output_path_canonical" in
"$repository_root" | "$repository_root"/*)
  fail "Output directory must be outside repository: $output_directory"
  ;;
esac

temporary_output=$(mktemp -d "$output_parent_canonical/.apmx-traces.XXXXXX")
cleanup() {
  if [ -d "$temporary_output" ]; then
    rm -rf "$temporary_output"
  fi
}
trap cleanup EXIT HUP INT TERM

trace_records_requested_target() {
  trace_path=$1
  toc_file=$(mktemp "$temporary_output/.toc.XXXXXX")
  "$xcrun_command" xctrace export --input "$trace_path" --toc --output "$toc_file"

  run_count=$(
    "$toc_parser" --xpath 'count(/trace-toc/run)' "$toc_file"
  ) || fail "Malformed trace TOC: $trace_path"
  [ "$run_count" = 1 ] || fail "Trace TOC must contain exactly one run: $trace_path"
  target_pid_count=$(
    "$toc_parser" --xpath 'count(/trace-toc/run/info/target/process/@pid)' "$toc_file"
  ) || fail "Malformed trace target: $trace_path"
  [ "$target_pid_count" = 1 ] || fail "Trace TOC target PID is missing or ambiguous: $trace_path"
  target_pid=$(
    "$toc_parser" --xpath 'string(/trace-toc/run/info/target/process/@pid)' "$toc_file"
  ) || fail "Malformed trace target PID: $trace_path"
  case "$target_pid" in
  '' | *[!0-9]*) fail "Trace TOC target PID is invalid: $trace_path" ;;
  esac
  target_process_count=$(
    "$toc_parser" --xpath "count(/trace-toc/run/processes/process[@pid='$target_pid'])" "$toc_file"
  ) || fail "Malformed trace process linkage: $trace_path"
  [ "$target_process_count" = 1 ] \
    || fail "Trace target process is missing or ambiguous: $trace_path"
  target_path_count=$(
    "$toc_parser" --xpath "count(/trace-toc/run/processes/process[@pid='$target_pid']/@path)" "$toc_file"
  ) || fail "Malformed trace process linkage: $trace_path"
  [ "$target_path_count" = 1 ] \
    || fail "Trace target process path is missing or ambiguous: $trace_path"
  target_path=$(
    "$toc_parser" --xpath "string(/trace-toc/run/processes/process[@pid='$target_pid']/@path)" "$toc_file"
  ) || fail "Malformed trace target process path: $trace_path"
  [ -f "$target_path" ] || fail "Trace target executable is missing: $trace_path"
  target_parent=$(dirname -- "$target_path")
  target_leaf=$(basename -- "$target_path")
  target_path_canonical=$(CDPATH= cd -- "$target_parent" && pwd -P)/$target_leaf
  [ "$target_path_canonical" = "$app_executable" ] \
    || fail "Trace target does not match requested executable: $trace_path"
}

record() {
  template=$1
  filename=$2
  trace_path="$temporary_output/$filename.trace"
  "$xcrun_command" xctrace record \
    --no-prompt \
    --template "$template" \
    --time-limit "$duration" \
    --output "$trace_path" \
    --launch -- "$app_executable"
  trace_records_requested_target "$trace_path"
}

record 'App Launch' app-launch
record 'Time Profiler' time-profiler
record 'Allocations' allocations
record 'Data Persistence' data-persistence
record 'System Trace' system-trace

mv "$temporary_output" "$output_path_canonical"
printf 'Performance traces saved outside the repository: %s\n' "$output_path_canonical"
