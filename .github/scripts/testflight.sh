#!/bin/bash
# Builds this fork's HaloPad (Xbox edition) for iPhone and iPad and, with App
# Store Connect credentials, uploads it to TestFlight for internal testing, as
# lasmith1689-sys/Glass-Rail does: the app is ad-hoc signed with its two memory
# entitlements, wrapped in an Xcode archive, and Xcode signs it for
# distribution during export with a cloud-managed certificate, using the App
# Store Connect API key. No certificates or provisioning profiles.
#
# Environment:
#   BUILD_NUMBER, APP_VERSION     required (the build number must grow with every upload)
#   HALOPAD_BUNDLE_ID             the App Store Connect app's bundle ID
#   APPLE_TEAM_ID, ASC_KEY_ID,    optional; without all four the script stops after a
#   ASC_ISSUER_ID, ASC_KEY_P8     dry-run archive. ASC_KEY_P8 is the text of the AuthKey_XXXX.p8 file.
set -euo pipefail

OUT="${RUNNER_TEMP:-/tmp}/testflight"
ARCHIVE="$OUT/HaloPad.xcarchive"
APP="$ARCHIVE/Products/Applications/HaloPad.app"
rm -rf "$OUT"
mkdir -p "$OUT"
export HALOPAD_BUNDLE_ID

echo "▶ Building HaloPad $HALOPAD_BUNDLE_ID $APP_VERSION ($BUILD_NUMBER)"
scripts/builder/build.sh --xbox-only --app-version "$APP_VERSION" --app-build "$BUILD_NUMBER" \
  --out "$OUT/builder" --ipa "$OUT/HaloPad-unsigned.ipa"

# ---------- the archive: the builder's app, with the metadata Xcode's own archives carry
mkdir -p "$ARCHIVE/Products/Applications"
ditto -x -k "$OUT/HaloPad-unsigned.ipa" "$OUT/ipa"
mv "$OUT/ipa/Payload/HaloPad.app" "$APP"
# ---------- the player's own maps, inside the app (HaloPadXbox.m links them):
# the release asset is the disc image converted from the player's Halo PC,
# encrypted with the HALOPAD_DATA_KEY secret
if [ -n "${HALOPAD_DATA_KEY:-}" ]; then
  echo "▶ Adding the maps"
  gh release download "$HALOPAD_DATA_RELEASE" -R "$GITHUB_REPOSITORY" -p halopad-data.bin -D "$OUT"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in "$OUT/halopad-data.bin" -out "$OUT/halo.xiso" \
    -pass env:HALOPAD_DATA_KEY
  rm -f "$OUT/halopad-data.bin"
  python3 scripts/xbox/extract-maps.py "$OUT/halo.xiso" "$APP/data/xbox" > "$OUT/maps.json"
  rm -f "$OUT/halo.xiso"
  if [ ! -f "$APP/data/xbox/maps/ui.map" ]; then
    echo "::error::The maps did not reach the app."
    exit 1
  fi
  echo "::notice title=Maps::$(ls "$APP/data/xbox/maps" | wc -l | tr -d ' ') maps, $(du -sh "$APP/data/xbox/maps" | cut -f1), inside the app."
fi
info="$APP/Info.plist"
sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
sdk_build=$(xcrun --sdk iphoneos --show-sdk-build-version)
xcode_version=$(xcodebuild -version | sed -n 's/^Xcode //p')
xcode_build=$(xcodebuild -version | sed -n 's/^Build version //p')
xcode_digits=$(printf '%s' "$xcode_version" | awk -F. '{printf "%02d%d%d", $1, $2, $3}')
plutil -replace DTPlatformName -string iphoneos "$info"
plutil -replace DTPlatformVersion -string "$sdk_version" "$info"
plutil -replace DTPlatformBuild -string "$sdk_build" "$info"
plutil -replace DTSDKName -string "iphoneos$sdk_version" "$info"
plutil -replace DTSDKBuild -string "$sdk_build" "$info"
plutil -replace DTXcode -string "$xcode_digits" "$info"
plutil -replace DTXcodeBuild -string "$xcode_build" "$info"
plutil -replace DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$info"
plutil -replace BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$info"
# (TLS and DTLS from the system and mbedTLS only: exempt)
plutil -replace ITSAppUsesNonExemptEncryption -bool NO "$info"
# the ad-hoc signature again, over the new Info.plist, keeping the entitlements
entitlements="$OUT/entitlements.plist"
codesign -d --entitlements - --xml "$APP" > "$entitlements"
# (plutil -extract reads dots as a key path, so the keys are looked up in Python)
python3 - "$entitlements" <<'PY'
import plistlib, sys
granted = plistlib.load(open(sys.argv[1], 'rb'))
for key in ('com.apple.developer.kernel.extended-virtual-addressing', 'com.apple.developer.kernel.increased-memory-limit'):
    if granted.get(key) is not True:
        print(f'::error::The app is missing the {key} entitlement HaloPad needs.')
        sys.exit(1)
print('::notice title=Entitlements::Both memory entitlements are present.')
PY
codesign --force --sign - --entitlements "$entitlements" "$APP"
plutil -p "$info" | grep -E '"CFBundleIdentifier"|"CFBundleShortVersionString"|"CFBundleVersion"|"MinimumOSVersion"|"DTSDKName"|"DTXcode"' || true

python3 - "$ARCHIVE/Info.plist" "$info" <<'PY'
import datetime, plistlib, sys
info = plistlib.load(open(sys.argv[2], 'rb'))
plistlib.dump({
    'ArchiveVersion': 2, 'Name': 'HaloPad', 'SchemeName': 'HaloPad',
    'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
    'ApplicationProperties': {
        'ApplicationPath': 'Applications/HaloPad.app', 'Architectures': ['arm64'],
        'CFBundleIdentifier': info['CFBundleIdentifier'],
        'CFBundleShortVersionString': info['CFBundleShortVersionString'],
        'CFBundleVersion': info['CFBundleVersion'], 'SigningIdentity': 'Sign to Run Locally',
    },
}, open(sys.argv[1], 'wb'))
PY

if [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ] || [ -z "${ASC_KEY_P8:-}" ]; then
  echo "::notice::HaloPad archive OK. Nothing was uploaded: add the App Store Connect secrets to send builds to TestFlight."
  exit 0
fi

key="$OUT/AuthKey_$ASC_KEY_ID.p8"
# Accept the .p8 text however it was pasted: Windows line endings, or without the BEGIN/END lines.
p8=$(printf '%s' "$ASC_KEY_P8" | tr -d '\r')
if [[ "$p8" != *"BEGIN PRIVATE KEY"* ]]; then
  p8=$(printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----' "$(printf '%s' "$p8" | tr -d ' \n' | fold -w 64)")
fi
(umask 077 && printf '%s\n' "$p8" > "$key")
unset p8
trap 'rm -f "$key"' EXIT

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$APPLE_TEAM_ID</string>
	<key>testFlightInternalTestingOnly</key>
	<true/>
	<key>uploadSymbols</key>
	<false/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

echo "▶ Signing and uploading to App Store Connect"
if ! xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$key" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" > "$OUT/export.log" 2>&1; then
  tail -n 60 "$OUT/export.log"
  log=$(cat "$OUT/export.log")
  hint="See the log above."
  case "$log" in
    *"No suitable application records"*|*"Cannot determine the Apple ID from Bundle ID"*)
      hint="The App Store Connect app record for $HALOPAD_BUNDLE_ID was not found. Check the bundle ID matches exactly." ;;
    *"xtended"*"irtual"*|*"ncreased"*"emory"*)
      hint="Turn on Extended Virtual Addressing and Increased Memory Limit for $HALOPAD_BUNDLE_ID on developer.apple.com." ;;
    *"NOT_AUTHORIZED"*|*"not authorized"*|*"credentials are missing or invalid"*|*"loud signing permission"*|*"does not have permission"*|*"invalid key"*|*"Invalid key"*)
      hint="Check the API key: it needs the Admin role, and ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 must all come from that key." ;;
    *"bundle version must be higher"*)
      hint="That build number was already used. Run the workflow again to get a new one." ;;
  esac
  echo "::error::Upload to TestFlight failed. $hint"
  exit 1
fi
grep -iE "upload|success|export" "$OUT/export.log" | tail -n 5 || true
echo "::notice::Uploaded HaloPad build $BUILD_NUMBER. It shows up in TestFlight once Apple finishes processing it, usually within 5-30 minutes."
