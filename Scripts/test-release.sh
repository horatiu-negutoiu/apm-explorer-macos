#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$repository_root/Scripts/verify-brand-assets.sh"
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

xcodebuild build \
  -project "$repository_root/APMExplorer.xcodeproj" \
  -scheme APMExplorer \
  -configuration 'Developer ID Release' \
  -destination 'generic/platform=macOS'
release_build_settings=$(xcodebuild -showBuildSettings \
  -project "$repository_root/APMExplorer.xcodeproj" \
  -scheme APMExplorer \
  -configuration 'Developer ID Release')
release_target_build_dir=$(printf '%s\n' "$release_build_settings" |
  sed -n 's/^[[:space:]]*TARGET_BUILD_DIR = //p' | head -n 1)
release_wrapper_name=$(printf '%s\n' "$release_build_settings" |
  sed -n 's/^[[:space:]]*WRAPPER_NAME = //p' | head -n 1)
"$repository_root/Scripts/verify-release-safety.sh" \
  "$release_target_build_dir/$release_wrapper_name"
