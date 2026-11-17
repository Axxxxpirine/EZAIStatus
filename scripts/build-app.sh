#!/bin/zsh
# Assemble build/EZAIStatus.app (binaire universel arm64 + x86_64).
#   scripts/build-app.sh            signature ad hoc, pour tester sur ce Mac
#   scripts/build-app.sh --release  signature Developer ID + runtime renforcé, prête pour la notarisation
set -euo pipefail
cd "${0:A:h}/.."

mode=${1:-dev}
app=build/EZAIStatus.app

swift build -c release --arch arm64 --arch x86_64 --product EZAIStatus
binary=$(swift build -c release --arch arm64 --arch x86_64 --product EZAIStatus --show-bin-path)/EZAIStatus

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/EZAIStatus"
cp Resources/Info.plist "$app/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/"

# Sparkle : framework embarqué (liens symboliques conservés), flux et clé publique depuis release.env.
mkdir -p "$app/Contents/Frameworks"
ditto "$(dirname "$binary")/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
feed=${SPARKLE_FEED_URL:-$(awk -F= '$1=="SPARKLE_FEED_URL" {print $2}' release.env)}
key=${SPARKLE_PUBLIC_KEY:-$(awk -F= '$1=="SPARKLE_PUBLIC_KEY" {print $2}' release.env)}
if [[ -n $feed && -n $key ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed" -c "Add :SUPublicEDKey string $key" "$app/Contents/Info.plist"
  echo "Mises à jour : $feed"
else
  echo "Mises à jour inactives (release.env vide)"
fi

if [[ $mode == --release ]]; then
  # Identité : SIGN_IDENTITY (empreinte SHA-1 ou nom), sinon la « Developer ID Application » valide qui expire le plus tard.
  identity=${SIGN_IDENTITY:-$(
    for hash in $(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2}'); do
      end=$(security find-certificate -a -Z -p -c "Developer ID Application" | awk -v h="$hash" '
        /SHA-1 hash:/ { keep = ($3 == h) } keep { print } /END CERTIFICATE/ { keep = 0 }' |
        openssl x509 -noout -enddate | cut -d= -f2)
      print "$(date -j -f '%b %e %T %Y %Z' "$end" +%s) $hash"
    done | sort -rn | awk 'NR==1 {print $2}'
  )}
  [[ -n $identity ]] || { echo "Aucune identité Developer ID trouvée." >&2; exit 1; }
  echo "Signature avec $identity"
  sign=(codesign --force --options runtime --timestamp --sign "$identity")
else
  sign=(codesign --force --sign -)
fi
# Signature de l'intérieur vers l'extérieur, comme le recommande Sparkle (pas de --deep).
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for xpc in "$sparkle"/XPCServices/*.xpc(N); do
  "${sign[@]}" --preserve-metadata=entitlements "$xpc"
done
"${sign[@]}" "$sparkle/Autoupdate" "$sparkle/Updater.app"
"${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
"${sign[@]}" "$app"
codesign --verify --strict "$app"
echo "OK : $PWD/$app"
