#!/bin/sh
set -eu

usage='usage: verify-app-store-release.sh /path/to/APM Explorer.app /path/to/screenshots /path/to/DistributionSummary.plist'
[ "$#" -eq 3 ] || {
  printf '%s\n' "$usage" >&2
  exit 64
}
app_path=$1
screenshot_directory=$2
distribution_summary=$3
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
screenshot_manifest="$repository_root/Distribution/AppStoreScreenshotManifest.sha256"

fail() {
  printf '%s\n' "App Store release verification failed: $1" >&2
  exit 1
}

for required_tool in codesign find grep sed shasum sips sort tr wc; do
  command -v "$required_tool" >/dev/null 2>&1 ||
    fail "required tool is unavailable: $required_tool"
done
[ -x /usr/libexec/PlistBuddy ] || fail "required tool is unavailable: PlistBuddy"

[ -d "$app_path" ] || fail "missing app bundle $app_path"
info_plist="$app_path/Contents/Info.plist"
[ -f "$info_plist" ] || fail "missing Info.plist $info_plist"
[ -d "$screenshot_directory" ] ||
  fail "missing screenshot directory $screenshot_directory"
[ -f "$distribution_summary" ] ||
  fail "missing distribution summary $distribution_summary"
[ -f "$screenshot_manifest" ] ||
  fail "missing screenshot manifest $screenshot_manifest"

plist_value_from() {
  plist_file=$1
  plist_key=$2
  if ! plist_result=$(/usr/libexec/PlistBuddy -c "Print :$plist_key" "$plist_file" 2>/dev/null); then
    fail "missing plist value $plist_key in $plist_file"
  fi
  printf '%s\n' "$plist_result"
}

plist_value() {
  plist_value_from "$info_plist" "$1"
}

assert_plist_value() {
  plist_key=$1
  expected_value=$2
  actual_value=$(plist_value "$plist_key")
  [ "$actual_value" = "$expected_value" ] ||
    fail "expected $plist_key=$expected_value, got $actual_value"
}

bundle_identifier=$(plist_value CFBundleIdentifier)
[ "$bundle_identifier" = "ca.horatiu.apmx" ] ||
  fail "expected bundle identifier ca.horatiu.apmx, got $bundle_identifier"
assert_plist_value CFBundleDisplayName "APM Explorer"
assert_plist_value CFBundleShortVersionString "1.0.0"
assert_plist_value CFBundleVersion "1"
assert_plist_value LSMinimumSystemVersion "13.0"
assert_plist_value LSUIElement "true"
assert_plist_value LSApplicationCategoryType "public.app-category.productivity"
assert_plist_value ITSAppUsesNonExemptEncryption "false"

if ! signature_details=$(codesign -dvv "$app_path" 2>&1); then
  fail "signature inspection failed"
fi
printf '%s\n' "$signature_details" | grep -Fq 'TeamIdentifier=87M55M486F' ||
  fail "expected TeamIdentifier 87M55M486F"

"$repository_root/Scripts/verify-release-safety.sh" "$app_path" >/dev/null

summary_value() {
  summary_key=$1
  if ! summary_result=$(/usr/libexec/PlistBuddy -c \
    "Print :'APM Explorer.pkg':0:$summary_key" \
    "$distribution_summary" 2>/dev/null); then
    fail "missing distribution summary value $summary_key"
  fi
  printf '%s\n' "$summary_result"
}

assert_summary_value() {
  summary_key=$1
  expected_value=$2
  actual_value=$(summary_value "$summary_key")
  [ "$actual_value" = "$expected_value" ] ||
    fail "expected distribution $summary_key=$expected_value, got $actual_value"
}

distribution_certificate=$(summary_value certificate:type)
case "$distribution_certificate" in
  'Apple Distribution'|'Cloud Managed Apple Distribution') ;;
  *) fail "expected an Apple Distribution certificate, got $distribution_certificate" ;;
esac

assert_summary_value name "APM Explorer.app"
assert_summary_value versionNumber "1.0.0"
assert_summary_value buildNumber "1"
assert_summary_value team:id "87M55M486F"
assert_summary_value architectures:0 "arm64"
if /usr/libexec/PlistBuddy -c \
  "Print :'APM Explorer.pkg':0:architectures:1" \
  "$distribution_summary" >/dev/null 2>&1; then
  fail "expected distribution architecture arm64 only"
fi
assert_summary_value entitlements:com.apple.application-identifier \
  "87M55M486F.ca.horatiu.apmx"
assert_summary_value entitlements:com.apple.developer.team-identifier "87M55M486F"
assert_summary_value entitlements:com.apple.security.app-sandbox "true"
if ! distribution_entitlements=$(/usr/libexec/PlistBuddy -c \
  "Print :'APM Explorer.pkg':0:entitlements" \
  "$distribution_summary" 2>/dev/null); then
  fail "missing distribution summary entitlements"
fi
actual_entitlement_keys=$(printf '%s\n' "$distribution_entitlements" |
  sed -n 's/^[[:space:]]*\([^=]*[^=[:space:]]\)[[:space:]]*=.*$/\1/p' |
  sort)
expected_entitlement_keys=$(printf '%s\n' \
  'com.apple.application-identifier' \
  'com.apple.developer.team-identifier' \
  'com.apple.security.app-sandbox')
[ "$actual_entitlement_keys" = "$expected_entitlement_keys" ] ||
  fail "distribution entitlements do not match the approved allow-list"
distribution_profile=$(summary_value profile:name)
case "$distribution_profile" in
  'Mac Team Store Provisioning Profile: ca.horatiu.apmx') ;;
  *) fail "expected Mac App Store provisioning profile, got $distribution_profile" ;;
esac

screenshot_count=$(find "$screenshot_directory" -maxdepth 1 -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l | tr -d ' ')
[ "$screenshot_count" -eq 2 ] ||
  fail "expected exactly two approved screenshots, got $screenshot_count"

first_manifest_entry=$(sed -n '1p' "$screenshot_manifest")
second_manifest_entry=$(sed -n '2p' "$screenshot_manifest")
first_manifest_name=${first_manifest_entry#*  }
second_manifest_name=${second_manifest_entry#*  }
[ "$first_manifest_name" = "apmx-preview-1.jpg" ] &&
  [ "$second_manifest_name" = "apmx-preview-2.jpg" ] ||
  fail "screenshot manifest must list apmx-preview-1.jpg then apmx-preview-2.jpg"
if sed -n '3,$p' "$screenshot_manifest" | grep -q '[^[:space:]]'; then
  fail "screenshot manifest must list apmx-preview-1.jpg then apmx-preview-2.jpg"
fi

for approved_screenshot in apmx-preview-1.jpg apmx-preview-2.jpg; do
  [ -f "$screenshot_directory/$approved_screenshot" ] ||
    fail "missing approved screenshot $approved_screenshot"
done

find "$screenshot_directory" -maxdepth 1 -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -print |
while IFS= read -r screenshot_path; do
  screenshot_name=${screenshot_path##*/}
  width=$(sips -g pixelWidth "$screenshot_path" 2>/dev/null |
    sed -n 's/^[[:space:]]*pixelWidth: //p')
  height=$(sips -g pixelHeight "$screenshot_path" 2>/dev/null |
    sed -n 's/^[[:space:]]*pixelHeight: //p')
  case "$width"x"$height" in
    1280x800|1440x900|2560x1600|2880x1800) ;;
    *) fail "unsupported screenshot dimensions ${width}x${height}: $screenshot_name" ;;
  esac

  has_alpha=$(sips -g hasAlpha "$screenshot_path" 2>/dev/null |
    sed -n 's/^[[:space:]]*hasAlpha: //p')
  [ "$has_alpha" != "yes" ] ||
    fail "screenshot has an alpha channel: $screenshot_name"
done

if ! (cd "$screenshot_directory" &&
  shasum -a 256 -c "$screenshot_manifest" >/dev/null 2>&1); then
  fail "approved screenshot hashes do not match the release manifest"
fi

printf '%s\n' \
  "App Store archive and export verified: ca.horatiu.apmx 1.0.0 (1), arm64, Apple Distribution, sandboxed, offline, approved screenshots match."
