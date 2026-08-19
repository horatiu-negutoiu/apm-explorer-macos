#!/bin/sh
set -eu

app_path=${1:?usage: verify-input-monitoring-signature.sh /path/to/APM\ Explorer.app}
expected_identifier=ca.horatiu.apmx
expected_team=87M55M486F

codesign --verify --deep --strict "$app_path"
details=$(codesign -dvv "$app_path" 2>&1)
identifier=$(printf '%s\n' "$details" | sed -n 's/^Identifier=//p')
team=$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')

if [ "$identifier" != "$expected_identifier" ]; then
  printf 'Invalid bundle code identifier: expected %s, got %s\n' \
    "$expected_identifier" "$identifier" >&2
  exit 1
fi

if [ "$team" != "$expected_team" ]; then
  printf 'Invalid signing team: expected %s, got %s\n' "$expected_team" "$team" >&2
  exit 1
fi

printf 'Input Monitoring identity verified: %s (%s)\n' "$identifier" "$team"
