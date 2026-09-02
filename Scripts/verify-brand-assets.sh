#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
asset_catalog="$repository_root/APMExplorer/Assets.xcassets"
project_file="$repository_root/APMExplorer.xcodeproj/project.pbxproj"
app_source="$repository_root/APMExplorer/APMExplorerApp.swift"

fail() {
  printf '%s\n' "Brand asset verification failed: $1" >&2
  exit 1
}

assert_png_dimensions() {
  image_file=$1
  expected_size=$2

  [ -f "$image_file" ] || fail "missing $image_file"
  image_format=$(sips -g format "$image_file" 2>/dev/null | sed -n 's/.*format: //p')
  width=$(sips -g pixelWidth "$image_file" 2>/dev/null | sed -n 's/.*pixelWidth: //p')
  height=$(sips -g pixelHeight "$image_file" 2>/dev/null | sed -n 's/.*pixelHeight: //p')
  [ "$image_format" = "png" ] || fail "$image_file is not a PNG"
  [ "$width" = "$expected_size" ] || fail "$image_file is ${width}px wide; expected ${expected_size}px"
  [ "$height" = "$expected_size" ] || fail "$image_file is ${height}px high; expected ${expected_size}px"
}

assert_png_has_alpha() {
  image_file=$1
  has_alpha=$(sips -g hasAlpha "$image_file" 2>/dev/null | sed -n 's/.*hasAlpha: //p')
  [ "$has_alpha" = "yes" ] || fail "$image_file does not have an alpha channel"
}

assert_catalog_entry() {
  catalog_file=$1
  expected_entry=$2
  compact_catalog=$(tr -d '[:space:]' < "$catalog_file")

  case "$compact_catalog" in
    *"$expected_entry"*) ;;
    *) fail "$catalog_file is missing catalog entry $expected_entry" ;;
  esac
}

assert_occurrence_count() {
  expected_count=$1
  search_text=$2
  search_file=$3
  actual_count=$(grep -F -c "$search_text" "$search_file" || true)
  [ "$actual_count" = "$expected_count" ] \
    || fail "$search_file contains $actual_count occurrences of $search_text; expected $expected_count"
}

for size in 16 32 64 128 256 512 1024; do
  assert_png_dimensions \
    "$asset_catalog/AppIcon.appiconset/apmx-logo-${size}.png" \
    "$size"
done

assert_png_dimensions \
  "$asset_catalog/MenuBarIcon.imageset/apmx-menubar-template-18.png" \
  18
assert_png_dimensions \
  "$asset_catalog/MenuBarIcon.imageset/apmx-menubar-template-36.png" \
  36
assert_png_has_alpha \
  "$asset_catalog/MenuBarIcon.imageset/apmx-menubar-template-18.png"
assert_png_has_alpha \
  "$asset_catalog/MenuBarIcon.imageset/apmx-menubar-template-36.png"

app_icon_catalog="$asset_catalog/AppIcon.appiconset/Contents.json"
assert_occurrence_count 10 '"filename"' "$app_icon_catalog"
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-16.png","idiom":"mac","scale":"1x","size":"16x16"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-32.png","idiom":"mac","scale":"2x","size":"16x16"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-32.png","idiom":"mac","scale":"1x","size":"32x32"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-64.png","idiom":"mac","scale":"2x","size":"32x32"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-128.png","idiom":"mac","scale":"1x","size":"128x128"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-256.png","idiom":"mac","scale":"2x","size":"128x128"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-256.png","idiom":"mac","scale":"1x","size":"256x256"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-512.png","idiom":"mac","scale":"2x","size":"256x256"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-512.png","idiom":"mac","scale":"1x","size":"512x512"}'
assert_catalog_entry "$app_icon_catalog" \
  '{"filename":"apmx-logo-1024.png","idiom":"mac","scale":"2x","size":"512x512"}'

menu_bar_catalog="$asset_catalog/MenuBarIcon.imageset/Contents.json"
assert_occurrence_count 2 '"filename"' "$menu_bar_catalog"
assert_catalog_entry "$menu_bar_catalog" \
  '{"filename":"apmx-menubar-template-18.png","idiom":"universal","scale":"1x"}'
assert_catalog_entry "$menu_bar_catalog" \
  '{"filename":"apmx-menubar-template-36.png","idiom":"universal","scale":"2x"}'

grep -q '"template-rendering-intent"[[:space:]]*:[[:space:]]*"template"' \
  "$menu_bar_catalog" \
  || fail "MenuBarIcon is not configured as a template image"
assert_occurrence_count 1 'path = Assets.xcassets;' "$project_file"
assert_occurrence_count 2 'Assets.xcassets in Resources' "$project_file"
assert_occurrence_count 3 \
  'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' \
  "$project_file"
grep -q 'MenuBarExtra("APM Explorer", image: "MenuBarIcon")' "$app_source" \
  || fail "MenuBarExtra does not use the custom image resource"

printf '%s\n' 'Brand assets verified.'
