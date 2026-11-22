#!/usr/bin/env bash
# Archives the app and uploads it to App Store Connect (TestFlight).
#
#   mise run release                          # iOS: archive + upload
#   mise run release -- --macos               # macOS: archive + upload
#   mise run release -- --no-upload           # archive + local export only, to check signing
#   mise run release -- --macos --no-upload
#
# The version and build number come from Config/Shared.xcconfig, so the iOS and
# macOS uploads of one release share them. Run `mise run bump:build` (which
# commits the new number) before each release; uploading the same build number
# twice for a platform fails at App Store Connect.
#
# Uploads authenticate with an App Store Connect API key, taken from:
#   ASC_KEY_ID      the key ID
#   ASC_ISSUER_ID   the issuer ID
#   ASC_KEY_PATH    the .p8 file, default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
# Set them in your shell or in mise.local.toml (git-ignored) under [env].

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export_options="$root/Config/ExportOptions.plist"

fail() {
  echo "release: $*" >&2
  exit 1
}

upload=true
platform=iOS
for arg in "$@"; do
  case "$arg" in
    --no-upload) upload=false ;;
    --macos) platform=macOS ;;
    *) fail "unknown option: $arg" ;;
  esac
done

out="$root/build/release/$platform"
archive="$out/RubyCuts.xcarchive"

cd "$root"

[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean, commit or stash first"

xcconfig_value() {
  sed -n "s/^$1 = //p" "$root/Config/Shared.xcconfig"
}
version="$(xcconfig_value MARKETING_VERSION)"
build_number="$(xcconfig_value CURRENT_PROJECT_VERSION)"
[[ "$build_number" =~ ^[0-9]+$ ]] || fail "could not read CURRENT_PROJECT_VERSION from Config/Shared.xcconfig"

auth=()
if $upload; then
  [[ -n "${ASC_KEY_ID:-}" ]] || fail "ASC_KEY_ID is not set (see the header of scripts/release.sh)"
  [[ -n "${ASC_ISSUER_ID:-}" ]] || fail "ASC_ISSUER_ID is not set"
  key_path="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [[ -f "$key_path" ]] || fail "API key file not found: $key_path"
  auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "Releasing RubyCuts $version ($build_number) for $platform from $(git rev-parse --short HEAD)"
rm -rf "$out"
mkdir -p "$out"

xcodebuild -project RubyCuts.xcodeproj -scheme RubyCuts -configuration Release \
  -destination "generic/platform=$platform" -archivePath "$archive" -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} archive

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
  echo "Uploaded $version ($build_number). It shows up in TestFlight after processing."
else
  echo "Archived and exported $version ($build_number) to $out/export (not uploaded)."
fi
