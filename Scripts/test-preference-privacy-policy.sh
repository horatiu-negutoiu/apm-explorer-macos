#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
verifier="$repository_root/Scripts/verify-preference-privacy.sh"
test_directory=$(mktemp -d /tmp/apmx-preference-policy-tests.XXXXXX)

cleanup() {
  rm -f \
    "$test_directory/allowed.keys" \
    "$test_directory/defaults-stub" \
    "$test_directory/empty.keys" \
    "$test_directory/empty.plist" \
    "$test_directory/invalid.plist" \
    "$test_directory/unexpected.keys" \
    "$test_directory/valid.plist"
  rmdir "$test_directory" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

expect_success_count() {
  expected_count=$1
  shift
  output=$("$@") || {
    printf '%s\n' 'Expected preference privacy verification to pass.' >&2
    exit 1
  }
  expected="Preference privacy verified: $expected_count allow-listed keys."
  [ "$output" = "$expected" ] || {
    printf '%s\n' 'Preference privacy verification exposed unexpected output.' >&2
    exit 1
  }
}

expect_failure() {
  description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'Expected preference privacy failure: %s.\n' "$description" >&2
    exit 1
  fi
}

allowed_keys="$test_directory/allowed.keys"
empty_keys="$test_directory/empty.keys"
unexpected_keys="$test_directory/unexpected.keys"
valid_plist="$test_directory/valid.plist"
empty_plist="$test_directory/empty.plist"
invalid_plist="$test_directory/invalid.plist"
defaults_stub="$test_directory/defaults-stub"

umask 077
printf '%s\n' \
  'inputMonitoring.hasBeenGranted' \
  'inputMonitoring.hasRequested' \
  'settings.launchAtLogin' \
  'settings.schemaVersion' \
  'NSWindow Frame ' \
  'NSWindow Frame analytics' >"$allowed_keys"
: >"$empty_keys"
printf '%s\n' 'NSArbitraryFrameworkKey' >"$unexpected_keys"

printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  '<key>inputMonitoring.hasBeenGranted</key><true/>' \
  '<key>inputMonitoring.hasRequested</key><true/>' \
  '<key>settings.launchAtLogin</key><false/>' \
  '<key>settings.schemaVersion</key><integer>3</integer>' \
  '<key>NSWindow Frame analytics</key><string>private-test-value</string>' \
  '</dict></plist>' >"$valid_plist"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict></dict></plist>' >"$empty_plist"
printf '%s\n' 'not a plist' >"$invalid_plist"

printf '%s\n' \
  '#!/bin/sh' \
  'exec /bin/cat "$APMX_TEST_PREFERENCES_PLIST"' >"$defaults_stub"
chmod +x "$defaults_stub"

expect_success_count 6 "$verifier" --key-list "$allowed_keys"
expect_success_count 5 "$verifier" --plist "$valid_plist"
expect_failure 'test override without internal mode' \
  /usr/bin/env \
  APMX_TEST_PREFERENCE_DEFAULTS_TOOL="$defaults_stub" \
  APMX_TEST_PREFERENCES_PLIST="$valid_plist" \
  "$verifier"
expect_success_count 5 \
  /usr/bin/env \
  APMX_INTERNAL_SCRIPT_TEST_MODE=preference-privacy \
  APMX_TEST_PREFERENCE_DEFAULTS_TOOL="$defaults_stub" \
  APMX_TEST_PREFERENCES_PLIST="$valid_plist" \
  "$verifier" --apmx-internal-test-mode

for prohibited_key in \
  'NSWindow Frame' \
  'NSWindow arbitrary' \
  'settings.capturePayload' \
  'inputMonitoring.rawKey'
do
  printf '%s\n' "$prohibited_key" >"$unexpected_keys"
  expect_failure "$prohibited_key" \
    "$verifier" --key-list "$unexpected_keys"
done

expect_failure 'empty key list' "$verifier" --key-list "$empty_keys"
expect_failure 'missing key list' \
  "$verifier" --key-list "$test_directory/missing.keys"
expect_failure 'missing plist' \
  "$verifier" --plist "$test_directory/missing.plist"
expect_failure 'invalid plist' "$verifier" --plist "$invalid_plist"
expect_failure 'valid empty plist' "$verifier" --plist "$empty_plist"
expect_failure 'defaults failure' \
  /usr/bin/env \
  APMX_INTERNAL_SCRIPT_TEST_MODE=preference-privacy \
  APMX_TEST_PREFERENCE_DEFAULTS_TOOL=/usr/bin/false \
  "$verifier" --apmx-internal-test-mode --domain ca.horatiu.apmx
expect_failure 'empty domain' "$verifier" --domain ''
expect_failure 'defaults produced invalid plist' \
  /usr/bin/env \
  APMX_INTERNAL_SCRIPT_TEST_MODE=preference-privacy \
  APMX_TEST_PREFERENCE_DEFAULTS_TOOL="$defaults_stub" \
  APMX_TEST_PREFERENCES_PLIST="$invalid_plist" \
  "$verifier" --apmx-internal-test-mode --domain ca.horatiu.apmx
expect_failure 'plutil failure' \
  /usr/bin/env \
  APMX_INTERNAL_SCRIPT_TEST_MODE=preference-privacy \
  APMX_TEST_PREFERENCE_PLUTIL_TOOL=/usr/bin/false \
  "$verifier" --apmx-internal-test-mode --plist "$valid_plist"
expect_failure 'extractor failure' \
  /usr/bin/env \
  APMX_INTERNAL_SCRIPT_TEST_MODE=preference-privacy \
  APMX_TEST_PREFERENCE_EXTRACTOR_TOOL=/usr/bin/false \
  "$verifier" --apmx-internal-test-mode --plist "$valid_plist"
expect_failure 'missing required tool' \
  /usr/bin/env \
  APMX_INTERNAL_SCRIPT_TEST_MODE=preference-privacy \
  APMX_TEST_PREFERENCE_EXTRACTOR_TOOL="$test_directory/missing-extractor" \
  "$verifier" --apmx-internal-test-mode --plist "$valid_plist"

printf '%s\n' 'Preference privacy policy tests passed.'
