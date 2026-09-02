#!/bin/sh
set -eu

usage='usage: test-verify-app-store-release.sh /path/to/APM Explorer.app /path/to/screenshots /path/to/DistributionSummary.plist'
[ "$#" -eq 3 ] || {
  printf '%s\n' "$usage" >&2
  exit 64
}
app_path=$1
screenshot_directory=$2
distribution_summary=$3
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
inspector="$repository_root/Scripts/verify-app-store-release.sh"
screenshot_manifest="$repository_root/Distribution/AppStoreScreenshotManifest.sha256"

fail() {
  printf '%s\n' "App Store release inspector test failed: $1" >&2
  exit 1
}

expect_failure() {
  expected_message=$1
  shift
  if output=$("$@" 2>&1); then
    fail "expected failure: $expected_message"
  fi
  printf '%s\n' "$output" | grep -Fqx "$expected_message" || {
    printf '%s\n' "$output" >&2
    fail "missing expected failure: $expected_message"
  }
}

[ -x "$inspector" ] || fail "missing executable inspector $inspector"
[ -d "$app_path" ] || fail "missing app bundle $app_path"
[ -d "$screenshot_directory" ] || fail "missing screenshot directory $screenshot_directory"
[ -f "$distribution_summary" ] || fail "missing distribution summary $distribution_summary"
[ -f "$screenshot_manifest" ] || fail "missing screenshot manifest $screenshot_manifest"

fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT HUP INT TERM

expect_failure \
  'usage: verify-app-store-release.sh /path/to/APM Explorer.app /path/to/screenshots /path/to/DistributionSummary.plist' \
  "$inspector" "$app_path" "$screenshot_directory" \
  "$distribution_summary" unexpected-fourth-argument

wrong_bundle_app="$fixture_root/Wrong Bundle.app"
cp -R "$app_path" "$wrong_bundle_app"
/usr/libexec/PlistBuddy -c \
  'Set :CFBundleIdentifier example.invalid.apmx' \
  "$wrong_bundle_app/Contents/Info.plist"
expect_failure \
  'App Store release verification failed: expected bundle identifier ca.horatiu.apmx, got example.invalid.apmx' \
  "$inspector" "$wrong_bundle_app" "$screenshot_directory" \
  "$distribution_summary"

wrong_encryption_app="$fixture_root/Wrong Encryption.app"
cp -R "$app_path" "$wrong_encryption_app"
/usr/libexec/PlistBuddy -c \
  'Set :ITSAppUsesNonExemptEncryption true' \
  "$wrong_encryption_app/Contents/Info.plist"
expect_failure \
  'App Store release verification failed: expected ITSAppUsesNonExemptEncryption=false, got true' \
  "$inspector" "$wrong_encryption_app" "$screenshot_directory" \
  "$distribution_summary"

wrong_distribution_summary="$fixture_root/Wrong DistributionSummary.plist"
cp "$distribution_summary" "$wrong_distribution_summary"
/usr/libexec/PlistBuddy -c \
  "Set :'APM Explorer.pkg':0:certificate:type Apple Development" \
  "$wrong_distribution_summary"
expect_failure \
  'App Store release verification failed: expected an Apple Distribution certificate, got Apple Development' \
  "$inspector" "$app_path" "$screenshot_directory" \
  "$wrong_distribution_summary"

network_entitlement_summary="$fixture_root/Network Entitlement DistributionSummary.plist"
cp "$distribution_summary" "$network_entitlement_summary"
/usr/libexec/PlistBuddy -c \
  "Add :'APM Explorer.pkg':0:entitlements:com.apple.security.network.client bool true" \
  "$network_entitlement_summary"
expect_failure \
  'App Store release verification failed: distribution entitlements do not match the approved allow-list' \
  "$inspector" "$app_path" "$screenshot_directory" \
  "$network_entitlement_summary"

unexpected_entitlement_summary="$fixture_root/Unexpected Entitlement DistributionSummary.plist"
cp "$distribution_summary" "$unexpected_entitlement_summary"
/usr/libexec/PlistBuddy -c \
  "Add :'APM Explorer.pkg':0:entitlements:com.apple.security.files.user-selected.read-only bool true" \
  "$unexpected_entitlement_summary"
expect_failure \
  'App Store release verification failed: distribution entitlements do not match the approved allow-list' \
  "$inspector" "$app_path" "$screenshot_directory" \
  "$unexpected_entitlement_summary"

missing_screenshot_directory="$fixture_root/missing-screenshot"
mkdir "$missing_screenshot_directory"
cp "$screenshot_directory/apmx-preview-1.jpg" "$missing_screenshot_directory/"
expect_failure \
  'App Store release verification failed: expected exactly two approved screenshots, got 1' \
  "$inspector" "$app_path" "$missing_screenshot_directory" \
  "$distribution_summary"

replacement_screenshot_directory="$fixture_root/replacement-screenshot"
mkdir "$replacement_screenshot_directory"
cp "$screenshot_directory/apmx-preview-2.jpg" "$replacement_screenshot_directory/"
cp "$screenshot_directory/apmx-preview-1.jpg" \
  "$replacement_screenshot_directory/replacement.jpg"
expect_failure \
  'App Store release verification failed: missing approved screenshot apmx-preview-1.jpg' \
  "$inspector" "$app_path" "$replacement_screenshot_directory" \
  "$distribution_summary"

altered_screenshot_directory="$fixture_root/altered-screenshot"
mkdir "$altered_screenshot_directory"
cp "$screenshot_directory/apmx-preview-2.jpg" \
  "$altered_screenshot_directory/apmx-preview-1.jpg"
cp "$screenshot_directory/apmx-preview-2.jpg" "$altered_screenshot_directory/"
expect_failure \
  'App Store release verification failed: approved screenshot hashes do not match the release manifest' \
  "$inspector" "$app_path" "$altered_screenshot_directory" \
  "$distribution_summary"

uppercase_screenshot_directory="$fixture_root/uppercase-screenshot"
mkdir "$uppercase_screenshot_directory"
cp "$screenshot_directory/apmx-preview-1.jpg" "$uppercase_screenshot_directory/"
cp "$screenshot_directory/apmx-preview-2.jpg" "$uppercase_screenshot_directory/"
cp "$screenshot_directory/apmx-preview-1.jpg" \
  "$uppercase_screenshot_directory/unexpected.JPG"
expect_failure \
  'App Store release verification failed: expected exactly two approved screenshots, got 3' \
  "$inspector" "$app_path" "$uppercase_screenshot_directory" \
  "$distribution_summary"

reordered_repository="$fixture_root/reordered-repository"
mkdir -p "$reordered_repository/Scripts" "$reordered_repository/Distribution"
ln -s "$repository_root/APMExplorer" "$reordered_repository/APMExplorer"
mkdir "$reordered_repository/APMXCore"
ln -s "$repository_root/APMXCore/Sources" \
  "$reordered_repository/APMXCore/Sources"
cp "$inspector" "$reordered_repository/Scripts/"
cp "$repository_root/Scripts/verify-release-safety.sh" \
  "$reordered_repository/Scripts/"
reordered_manifest="$reordered_repository/Distribution/AppStoreScreenshotManifest.sha256"
{
  sed -n '2p' "$screenshot_manifest"
  sed -n '1p' "$screenshot_manifest"
} >"$reordered_manifest"
expect_failure \
  'App Store release verification failed: screenshot manifest must list apmx-preview-1.jpg then apmx-preview-2.jpg' \
  "$reordered_repository/Scripts/verify-app-store-release.sh" \
  "$app_path" "$screenshot_directory" "$distribution_summary"

wrong_screenshot_directory="$fixture_root/screenshots"
mkdir "$wrong_screenshot_directory"
cp "$screenshot_directory/apmx-preview-2.jpg" "$wrong_screenshot_directory/"
sips -z 801 1280 \
  "$screenshot_directory/apmx-preview-1.jpg" \
  --out "$wrong_screenshot_directory/apmx-preview-1.jpg" >/dev/null
expect_failure \
  'App Store release verification failed: unsupported screenshot dimensions 1280x801: apmx-preview-1.jpg' \
  "$inspector" "$app_path" "$wrong_screenshot_directory" \
  "$distribution_summary"

"$inspector" "$app_path" "$screenshot_directory" \
  "$distribution_summary"
