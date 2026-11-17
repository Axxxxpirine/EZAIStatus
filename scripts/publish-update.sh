#!/bin/zsh
# Prépare une mise à jour Sparkle dans build/updates/ : zip notarisé versionné et appcast.xml signé (EdDSA).
# Le contenu de build/updates/ se dépose tel quel à l'adresse du flux (dossier de SPARKLE_FEED_URL).
#   scripts/publish-update.sh                   notarise puis génère l'appcast
#   scripts/publish-update.sh --skip-notarize   réutilise build/EZAIStatus.zip déjà notarisé
# Notes de version facultatives : notes/<version>.md (reprises par Sparkle dans sa fenêtre).
# Clé privée : trousseau (generate_keys), ou fichier via SPARKLE_KEY_FILE (essais locaux).
set -euo pipefail
cd "${0:A:h}/.."

feed=${SPARKLE_FEED_URL:-$(awk -F= '$1=="SPARKLE_FEED_URL" {print $2}' release.env)}
[[ -n $feed ]] || { echo "SPARKLE_FEED_URL vide dans release.env." >&2; exit 1; }
[[ ${1:-} == --skip-notarize ]] || scripts/notarize-xcode.sh

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/EZAIStatus.app/Contents/Info.plist)
grep -q SUFeedURL build/EZAIStatus.app/Contents/Info.plist ||
  { echo "L'app construite n'a pas d'adresse de flux : release.env était vide au build." >&2; exit 1; }

mkdir -p build/updates
cp build/EZAIStatus.zip "build/updates/EZAIStatus-$version.zip"
[[ -f notes/$version.md ]] && cp "notes/$version.md" "build/updates/EZAIStatus-$version.md"

tools=(.build/artifacts/**/Sparkle/bin(N/[1]))
[[ -n ${tools:-} ]] || { echo "Outils Sparkle introuvables : lancer swift package resolve." >&2; exit 1; }
key_args=()
[[ -n ${SPARKLE_KEY_FILE:-} ]] && key_args=(--ed-key-file "$SPARKLE_KEY_FILE")
"$tools[1]/generate_appcast" "${key_args[@]}" --download-url-prefix "${feed%/*}/" build/updates
echo "À déposer dans ${feed%/*}/ : $PWD/build/updates/"
