#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$repository_root/build/PermissionTestDerivedData"
app_path="$derived_data/Build/Products/Debug/APM Explorer.app"

xcodebuild build \
  -project "$repository_root/APMExplorer.xcodeproj" \
  -scheme APMExplorer \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data"

"$repository_root/Scripts/verify-input-monitoring-signature.sh" "$app_path"

printf '\nPermission-test app ready at:\n%s\n' "$app_path"
printf 'Quit every other APM Explorer copy, remove the old Input Monitoring row, then launch this exact app.\n'
