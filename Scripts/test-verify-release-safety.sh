#!/bin/sh
set -eu

app_path=${1:?usage: test-verify-release-safety.sh /path/to/APM Explorer.app}
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
inspector="$repository_root/Scripts/verify-release-safety.sh"
tool_directory=$(mktemp -d)
rg_directory=$(dirname "$(command -v rg)")
tool_path="$tool_directory:$rg_directory:/usr/bin:/bin"
trap 'rm -rf "$tool_directory"' EXIT HUP INT TERM

write_shim() {
  tool_name=$1
  tool_status=$2
  printf '%s\n' '#!/bin/sh' "exit $tool_status" >"$tool_directory/$tool_name"
  chmod +x "$tool_directory/$tool_name"
}

expect_failure() {
  expected_message=$1
  shift
  if output=$("$@" 2>&1); then
    printf '%s\n' "Expected release inspector failure: $expected_message" >&2
    exit 1
  fi
  printf '%s\n' "$output" | grep -Fqx "$expected_message"
}

write_shim otool 2
expect_failure \
  'Release safety verification failed: linked framework inspection failed' \
  env PATH="$tool_path" "$inspector" "$app_path"
rm -f "$tool_directory/otool"

write_shim rg 2
expect_failure \
  'Release safety verification failed: source inspection failed' \
  env PATH="$tool_path" "$inspector" "$app_path"
rm -f "$tool_directory/rg"

write_shim rg 1
env PATH="$tool_path" "$inspector" "$app_path"
