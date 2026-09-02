#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
helper="$repo_root/Scripts/capture-performance-traces.sh"
fixture_root=$(mktemp -d /tmp/apmx-capture-tests.XXXXXX)

cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "expected failure: $*"
  fi
}

app="$fixture_root/Fixture.app"
mkdir -p "$app/Contents/MacOS"
plutil -create xml1 "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Fixture "$app/Contents/Info.plist"
: > "$app/Contents/MacOS/Fixture"
chmod +x "$app/Contents/MacOS/Fixture"
app_canonical=$(CDPATH= cd -- "$app" && pwd -P)
other_app="$fixture_root/Other.app"
mkdir -p "$other_app/Contents/MacOS"
plutil -create xml1 "$other_app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Other "$other_app/Contents/Info.plist"
: > "$other_app/Contents/MacOS/Other"
chmod +x "$other_app/Contents/MacOS/Other"
other_executable="$(CDPATH= cd -- "$other_app/Contents/MacOS" && pwd -P)/Other"

expect_failure "$helper" "$fixture_root/missing.app" "$fixture_root/missing-output" 1s
invalid_app="$fixture_root/Invalid.app"
mkdir -p "$invalid_app/Contents/MacOS"
plutil -create xml1 "$invalid_app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string Missing "$invalid_app/Contents/Info.plist"
expect_failure "$helper" "$invalid_app" "$fixture_root/invalid-output" 1s
expect_failure "$helper" "$app" "$repo_root/task-5-output-inside-repository" 1s

ln -s "$repo_root" "$fixture_root/repository-link"
expect_failure "$helper" "$app" "$fixture_root/repository-link/task-5-symlink-output" 1s

count_file="$fixture_root/count"
printf '0\n' > "$count_file"
fake_xcrun="$repo_root/Scripts/test-support/xcrun"
export PATH="$repo_root/Scripts/test-support:$PATH"
export APMX_CAPTURE_TEST_COUNT_FILE="$count_file"
export APMX_CAPTURE_TEST_TIME_LIMIT=1s

run_helper() {
  /usr/bin/env \
    APMX_INTERNAL_SCRIPT_TEST_MODE=capture-performance-traces \
    APMX_XCRUN_COMMAND="$fake_xcrun" \
    "$helper" --apmx-internal-test-mode "$@"
}

expect_failure "$fake_xcrun" xctrace record
expect_failure "$fake_xcrun" xctrace export

expect_failure \
  /usr/bin/env APMX_XCRUN_COMMAND="$fake_xcrun" \
  "$helper" "$app" "$fixture_root/override-without-mode" 1s

partial_output="$fixture_root/partial-output"
export APMX_CAPTURE_TEST_FAIL_AT=3
expect_failure run_helper "$app" "$partial_output" 1s
[ ! -e "$partial_output" ] || fail "failed capture created final output"
[ -z "$(find "$fixture_root" -maxdepth 1 -name '.apmx-traces.*' -print -quit)" ] || fail "failed capture left temporary output"

printf '0\n' > "$count_file"
unset APMX_CAPTURE_TEST_FAIL_AT
run_helper "$app" "$partial_output" 1s
[ -d "$partial_output" ] || fail "retry did not create final output"
[ "$(find "$partial_output" -maxdepth 1 -name '*.trace' -type d | wc -l | tr -d ' ')" = 5 ] || fail "retry did not create five traces"

expect_toc_failure() {
  mode=$1
  output="$fixture_root/$mode-output"
  printf '0\n' > "$count_file"
  export APMX_CAPTURE_TEST_TARGET_MODE="$mode"
  expect_failure run_helper "$app" "$output" 1s
  [ ! -e "$output" ] || fail "$mode created final output"
  [ -z "$(find "$fixture_root" -maxdepth 1 -name '.apmx-traces.*' -print -quit)" ] || fail "$mode left temporary output"
}

export APMX_CAPTURE_TEST_OTHER_EXECUTABLE="$other_executable"
expect_toc_failure non_target_app
expect_toc_failure missing_pid_linkage
expect_toc_failure duplicate_target_process
expect_toc_failure missing_target_path
expect_toc_failure multiple_target_nodes
expect_toc_failure malformed_xml

printf 'capture-performance-traces tests passed\n'
