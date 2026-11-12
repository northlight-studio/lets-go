#!/bin/bash
# Archive Release, sign for the App Store, upload to TestFlight.
# The build number is one more than the highest Apple has (or $BUILD_NUMBER), so builds
# from this Mac and from GitHub Actions never collide and nothing gets committed.
#
# Signing (archive and export) uses Let's Go's own Apple Distribution certificate, kept in a dedicated
# keychain (~/Library/Keychains/letsgo-signing.keychain-db) whose password lives in
# ~/.appstoreconnect/letsgo-signing/. That keychain never prompts, so this runs
# unattended. scripts/setup-signing.sh rebuilds it on a new machine.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN="$HOME/.appstoreconnect/letsgo-signing"
KEY_JSON="$HOME/.appstoreconnect/letsgo_asc_api_key.json"
KEY_ID=$(python3 -c "import json;print(json.load(open('$KEY_JSON'))['key_id'])")
ISSUER=$(python3 -c "import json;print(json.load(open('$KEY_JSON'))['issuer_id'])")
KEY_P8="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
CERT_SHA1=$(openssl x509 -in "$SIGN/dist.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')

python3 scripts/asc.py app >/dev/null || { echo "No App Store Connect app for com.yasser100ali.letsgo yet."; exit 1; }
security unlock-keychain -p "$(cat "$SIGN/keychain_password")" "$HOME/Library/Keychains/letsgo-signing.keychain-db"

BUILD=${BUILD_NUMBER:-$(python3 scripts/asc.py next-build)}
OUT="build/$BUILD"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "Archiving build $BUILD"
# Sign the archive with the distribution cert straight from its own keychain. Automatic
# signing would reach for the login keychain, which a background runner can't open.
# The profile goes in through LETSGO_PROFILE_SPECIFIER, which only the app target reads (project.yml):
# Swift packages' resource bundles (Stripe's) fail the archive if they're handed a profile.
KEYCHAIN="$HOME/Library/Keychains/letsgo-signing.keychain-db"
xcodebuild archive -project ios/LetsGo.xcodeproj -scheme LetsGo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/LetsGo.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD" DEVELOPMENT_TEAM=X3HMA23KKN \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$CERT_SHA1" LETSGO_PROFILE_SPECIFIER="LetsGo AppStore" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" -quiet

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>X3HMA23KKN</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$CERT_SHA1</string>
  <key>provisioningProfiles</key><dict><key>com.yasser100ali.letsgo</key><string>LetsGo AppStore</string></dict>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

echo "Signing build $BUILD"
xcodebuild -exportArchive -archivePath "$OUT/LetsGo.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" -quiet

echo "Uploading build $BUILD"
xcrun altool --upload-app -f "$OUT/export/LetsGo.ipa" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
echo "Uploaded build $BUILD. Internal testers get it once Apple finishes processing (usually 5-15 min)."
