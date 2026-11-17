#!/bin/zsh
# Notarise EZAIStatus avec le compte connecté dans Xcode (sans profil notarytool), puis produit build/EZAIStatus.zip.
# 1. build/signature Developer ID ; 2. archive Xcode fabriquée à partir de l'app ; 3. envoi à Apple par xcodebuild ;
# 4. attente de la validation et récupération de l'app agrafée.
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh --release
# Sorties capturées d'abord : avec pipefail, un « | head » ou un « awk … exit » couperait le tuyau (SIGPIPE, code 141).
signature=$(codesign -dvv build/EZAIStatus.app 2>&1)
identity_name=$(print -r -- "$signature" | awk -F= '/^Authority=Developer ID Application/ && !found {print $2; found=1}')
team=$(print -r -- "$signature" | awk -F= '/^TeamIdentifier=/ {print $2}')
identities=$(security find-identity -v -p codesigning)
hash=$(print -r -- "$identities" | awk -v n="$identity_name" 'index($0, n) && !found {print $2; found=1}')
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)

archive=build/EZAIStatus.xcarchive
rm -rf "$archive" build/export build/notarized
mkdir -p "$archive/Products/Applications"
ditto build/EZAIStatus.app "$archive/Products/Applications/EZAIStatus.app"
cat > "$archive/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/EZAIStatus.app</string>
    <key>Architectures</key><array><string>arm64</string><string>x86_64</string></array>
    <key>CFBundleIdentifier</key><string>$bundle</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>SigningIdentity</key><string>$identity_name</string>
    <key>Team</key><string>$team</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>EZAIStatus</string>
  <key>SchemeName</key><string>EZAIStatus</string>
</dict></plist>
EOF
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$hash</string>
</dict></plist>
EOF

echo "Envoi à la notarisation (compte Xcode, équipe $team)…"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates

echo "Attente de la validation d'Apple (jusqu'à 30 min)…"
for attempt in {1..60}; do
  if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath build/notarized >/dev/null 2>&1; then
    break
  fi
  (( attempt == 60 )) && { echo "Toujours pas validée : relancer plus tard xcodebuild -exportNotarizedApp." >&2; exit 1; }
  sleep 30
done

rm -rf build/EZAIStatus.app
ditto build/notarized/EZAIStatus.app build/EZAIStatus.app
xcrun stapler validate build/EZAIStatus.app
spctl --assess --type execute --verbose build/EZAIStatus.app
ditto -c -k --keepParent build/EZAIStatus.app build/EZAIStatus.zip
echo "Prête à distribuer : $PWD/build/EZAIStatus.zip"
