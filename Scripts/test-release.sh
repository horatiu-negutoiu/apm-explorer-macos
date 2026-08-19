#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

swift test --package-path "$repository_root/APMXCore"
xcodebuild test \
  -project "$repository_root/APMExplorer.xcodeproj" \
  -scheme APMExplorer \
  -destination 'platform=macOS'

build_settings=$(xcodebuild -showBuildSettings \
  -project "$repository_root/APMExplorer.xcodeproj" \
  -scheme APMExplorer \
  -configuration Debug)
target_build_dir=$(printf '%s\n' "$build_settings" | sed -n 's/^[[:space:]]*TARGET_BUILD_DIR = //p' | head -n 1)
wrapper_name=$(printf '%s\n' "$build_settings" | sed -n 's/^[[:space:]]*WRAPPER_NAME = //p' | head -n 1)

"$repository_root/Scripts/verify-input-monitoring-signature.sh" \
  "$target_build_dir/$wrapper_name"
