#!/bin/sh
set -eu

app_path=${1:?usage: verify-release-safety.sh /path/to/APM Explorer.app}
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  printf '%s\n' "Release safety verification failed: $1" >&2
  exit 1
}

for required_tool in rg otool codesign lipo plutil grep sed mktemp; do
  command -v "$required_tool" >/dev/null 2>&1 ||
    fail "required tool is unavailable: $required_tool"
done
[ -x /usr/libexec/PlistBuddy ] || fail "required tool is unavailable: PlistBuddy"

[ -d "$app_path" ] || fail "missing app bundle $app_path"
info_plist="$app_path/Contents/Info.plist"
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")
executable="$app_path/Contents/MacOS/$executable_name"
[ -x "$executable" ] || fail "missing executable $executable"

if ! architectures=$(lipo -archs "$executable"); then
  fail "architecture inspection failed"
fi
[ "$architectures" = "arm64" ] || fail "expected arm64 only, got $architectures"

codesign --verify --deep --strict "$app_path" || fail "signature verification failed"
if ! signature_details=$(codesign -dvv "$app_path" 2>&1); then
  fail "signature inspection failed"
fi
printf '%s\n' "$signature_details" | grep -q 'flags=.*runtime' \
  || fail "Hardened Runtime flag is missing"

entitlements_file=$(mktemp)
trap 'rm -f "$entitlements_file"' EXIT HUP INT TERM
codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null ||
  fail "entitlement inspection failed"
if ! sandbox_entitlement=$(plutil -extract 'com\.apple\.security\.app-sandbox' raw "$entitlements_file"); then
  fail "entitlement inspection failed"
fi
[ "$sandbox_entitlement" = true ] || fail "App Sandbox entitlement is missing"
if ! entitlement_description=$(plutil -p "$entitlements_file"); then
  fail "entitlement inspection failed"
fi
entitlement_keys=$(printf '%s\n' "$entitlement_description" |
  sed -n 's/^  "\([^"]*\)".*/\1/p')
[ "$entitlement_keys" = "com.apple.security.app-sandbox" ] \
  || fail "unexpected entitlement set: $entitlement_keys"

if ! linked_libraries=$(otool -L "$executable"); then
  fail "linked framework inspection failed"
fi
if printf '%s\n' "$linked_libraries" |
  grep -Eiq 'Sparkle|Sentry|Telemetry|Mixpanel|FirebaseAnalytics|CFNetwork\.framework|Network\.framework'
then
  fail "prohibited linked analytics, updater, or networking framework"
fi

if rg -n \
  '^[[:space:]]*import[[:space:]]+(Network|CFNetwork)|URLSession|NWConnection|SentrySDK|SUUpdater|SPUUpdater|TelemetryClient|Mixpanel|FirebaseAnalytics|Crashlytics|MXMetricManager|NSSetUncaughtExceptionHandler' \
  "$repository_root/APMExplorer" "$repository_root/APMXCore/Sources"
then
  fail "prohibited networking, analytics, telemetry, or updater integration"
else
  source_scan_status=$?
fi
[ "$source_scan_status" -eq 1 ] || fail "source inspection failed"

printf '%s\n' "Release safety verified: arm64, Hardened Runtime, sandbox-only, offline."
