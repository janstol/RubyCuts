#!/usr/bin/env bash
# Archives the iOS app and uploads it to App Store Connect (TestFlight).
#
#   mise run release                  # archive + upload
#   mise run release -- --no-upload   # archive + local export only, to check signing
#
# The build number is the commit count of HEAD, so it only goes up and needs no
# commit of its own. Override it with BUILD_NUMBER=123 if needed. Uploading the
# same commit twice fails at App Store Connect (duplicate build number).
#
# Uploads authenticate with an App Store Connect API key, taken from:
#   ASC_KEY_ID      the key ID
#   ASC_ISSUER_ID   the issuer ID
#   ASC_KEY_PATH    the .p8 file, default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
# Set them in your shell or in mise.local.toml (git-ignored) under [env].

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/release"
archive="$out/RubyCuts.xcarchive"
export_options="$root/Config/ExportOptions.plist"

fail() {
  echo "release: $*" >&2
  exit 1
}

upload=true
[[ "${1:-}" == "--no-upload" ]] && upload=false

cd "$root"

[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean, commit or stash first"

build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "could not work out a build number"

auth=()
if $upload; then
  [[ -n "${ASC_KEY_ID:-}" ]] || fail "ASC_KEY_ID is not set (see the header of scripts/release.sh)"
  [[ -n "${ASC_ISSUER_ID:-}" ]] || fail "ASC_ISSUER_ID is not set"
  key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [[ -f "$key_path" ]] || fail "API key file not found: $key_path"
  auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "Releasing RubyCuts build $build_number ($(git rev-parse --short HEAD))"
rm -rf "$out"
mkdir -p "$out"

xcodebuild -project RubyCuts.xcodeproj -scheme RubyCuts -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} "CURRENT_PROJECT_VERSION=$build_number" archive

# The export options say "upload"; for a dry run, export locally instead.
options="$export_options"
if ! $upload; then
  options="$out/ExportOptions-local.plist"
  cp "$export_options" "$options"
  plutil -replace destination -string export "$options"
fi

xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
  -exportPath "$out/export" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}

if $upload; then
  echo "Uploaded build $build_number. It shows up in TestFlight after processing."
else
  echo "Archived and exported build $build_number to $out/export (not uploaded)."
fi
