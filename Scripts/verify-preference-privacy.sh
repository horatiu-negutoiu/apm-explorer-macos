#!/bin/sh
set -eu

fail() {
  printf '%s\n' "Preference privacy verification failed: $1" >&2
  exit 1
}

usage() {
  fail 'usage: verify-preference-privacy.sh [--domain domain | --plist path | --key-list path]'
}

internal_test_mode=false
if [ "${1:-}" = --apmx-internal-test-mode ]; then
  [ "${APMX_INTERNAL_SCRIPT_TEST_MODE:-}" = preference-privacy ] \
    || fail 'internal preference test mode was not explicitly validated.'
  internal_test_mode=true
  shift
fi

test_override_present=false
if [ "${APMX_TEST_PREFERENCE_DEFAULTS_TOOL+x}" = x ] \
  || [ "${APMX_TEST_PREFERENCE_PLUTIL_TOOL+x}" = x ] \
  || [ "${APMX_TEST_PREFERENCE_EXTRACTOR_TOOL+x}" = x ] \
  || [ "${APMX_TEST_PREFERENCES_PLIST+x}" = x ]
then
  test_override_present=true
fi
[ "$test_override_present" = false ] || [ "$internal_test_mode" = true ] \
  || fail 'test overrides require explicit internal preference test mode.'

mode=domain
domain=ca.horatiu.apmx
input_path=''

case $# in
  0)
    ;;
  2)
    case $1 in
      --domain)
        mode=domain
        domain=$2
        ;;
      --plist)
        mode=plist
        input_path=$2
        ;;
      --key-list)
        mode=key-list
        input_path=$2
        ;;
      *)
        usage
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac

case $domain in
  ''|-*)
    [ "$mode" != domain ] || fail 'invalid preferences domain.'
    ;;
esac

umask 077
temporary_directory=$(/usr/bin/mktemp -d /tmp/apmx-preference-privacy.XXXXXX) ||
  fail 'could not create private temporary storage.'
plist_file="$temporary_directory/preferences.plist"
json_file="$temporary_directory/preferences.json"
keys_file="$temporary_directory/preference-keys.txt"
diagnostics_file="$temporary_directory/diagnostics.txt"

cleanup() {
  /bin/rm -f "$plist_file" "$json_file" "$keys_file" "$diagnostics_file"
  /bin/rmdir "$temporary_directory" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ "$mode" = key-list ]; then
  [ -f "$input_path" ] && [ -r "$input_path" ] || fail 'missing key-list input.'
  [ -s "$input_path" ] || fail 'empty key stream.'
  keys_source=$input_path
else
  defaults_tool=/usr/bin/defaults
  plutil_tool=/usr/bin/plutil
  extractor_tool=/usr/bin/ruby
  if [ "$internal_test_mode" = true ]; then
    defaults_tool=${APMX_TEST_PREFERENCE_DEFAULTS_TOOL:-$defaults_tool}
    plutil_tool=${APMX_TEST_PREFERENCE_PLUTIL_TOOL:-$plutil_tool}
    extractor_tool=${APMX_TEST_PREFERENCE_EXTRACTOR_TOOL:-$extractor_tool}
  fi

  [ -x "$plutil_tool" ] || fail 'required plist tool is unavailable.'
  [ -x "$extractor_tool" ] || fail 'required key extractor is unavailable.'

  if [ "$mode" = domain ]; then
    [ -x "$defaults_tool" ] || fail 'required defaults tool is unavailable.'
    if ! "$defaults_tool" export "$domain" - \
      >"$plist_file" 2>"$diagnostics_file"
    then
      fail 'preferences domain export failed.'
    fi
    [ -s "$plist_file" ] || fail 'preferences domain export was empty.'
    plist_source=$plist_file
  else
    [ -f "$input_path" ] && [ -r "$input_path" ] || fail 'missing plist input.'
    plist_source=$input_path
  fi

  if ! "$plutil_tool" -lint "$plist_source" \
    >/dev/null 2>"$diagnostics_file"
  then
    fail 'plist validation failed.'
  fi
  if ! "$plutil_tool" -convert json -o "$json_file" "$plist_source" \
    2>"$diagnostics_file"
  then
    fail 'plist conversion failed.'
  fi
  [ -s "$json_file" ] || fail 'plist conversion produced no data.'

  if ! "$extractor_tool" -rjson -e '
    object = JSON.parse(File.binread(ARGV.fetch(0)))
    exit 2 unless object.is_a?(Hash)
    keys = object.keys
    exit 3 if keys.any? { |key| key.include?("\n") || key.include?("\0") }
    keys.sort.each { |key| puts key }
  ' "$json_file" >"$keys_file" 2>"$diagnostics_file"
  then
    fail 'preference key extraction failed.'
  fi
  [ -s "$keys_file" ] || fail 'empty key stream.'
  keys_source=$keys_file
fi

key_count=0
while IFS= read -r preference_key || [ -n "$preference_key" ]; do
  [ -n "$preference_key" ] || fail 'empty preference key.'
  case "$preference_key" in
    inputMonitoring.hasBeenGranted|\
    inputMonitoring.hasRequested|\
    settings.launchAtLogin|\
    settings.schemaVersion|\
    NSWindow\ Frame\ *)
      ;;
    *)
      fail 'unexpected key.'
      ;;
  esac
  key_count=$((key_count + 1))
done <"$keys_source"

[ "$key_count" -gt 0 ] || fail 'empty key stream.'

printf 'Preference privacy verified: %s allow-listed keys.\n' "$key_count"
