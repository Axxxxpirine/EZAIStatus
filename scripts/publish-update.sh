#!/bin/zsh
# Prépare une mise à jour Sparkle dans build/updates/ : zip notarisé versionné et appcast.xml signé (EdDSA).
#   scripts/publish-update.sh                   notarise puis génère l'appcast
#   scripts/publish-update.sh --skip-notarize   réutilise build/EZAIStatus.zip déjà notarisé
# Ensuite : le zip va à l'adresse SPARKLE_DOWNLOAD_PREFIX (Release GitHub de la version), puis appcast.xml
# à l'adresse SPARKLE_FEED_URL. Dans cet ordre : l'appcast ne doit jamais annoncer un zip absent.
# Notes de version facultatives : notes/<version>.md ou .html (reprises par Sparkle dans sa fenêtre).
# Clé privée : trousseau (generate_keys), ou fichier via SPARKLE_KEY_FILE (essais locaux).
set -euo pipefail
cd "${0:A:h}/.."

setting() { print -r -- "${(P)1:-$(sed -n "s/^$1=//p" release.env)}" }
feed=$(setting SPARKLE_FEED_URL)
[[ -n $feed ]] || { echo "SPARKLE_FEED_URL vide dans release.env." >&2; exit 1; }
[[ ${1:-} == --skip-notarize ]] || scripts/notarize-xcode.sh

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/EZAIStatus.app/Contents/Info.plist)
grep -q SUFeedURL build/EZAIStatus.app/Contents/Info.plist ||
  { echo "L'app construite n'a pas d'adresse de flux : release.env était vide au build." >&2; exit 1; }
prefix=$(setting SPARKLE_DOWNLOAD_PREFIX)
prefix=${${prefix:-${feed%/*}/}//VERSION/$version}

# Un seul zip dans le dossier : l'appcast n'annonce que la dernière version, à l'adresse de sa propre Release.
rm -rf build/updates
mkdir -p build/updates
cp build/EZAIStatus.zip "build/updates/EZAIStatus-$version.zip"
for notes in notes/$version.(md|html)(N); do cp "$notes" "build/updates/EZAIStatus-$version.${notes:e}"; done

tools=(.build/artifacts/**/Sparkle/bin(N/[1]))
[[ -n ${tools:-} ]] || { echo "Outils Sparkle introuvables : lancer swift package resolve." >&2; exit 1; }
key_args=()
[[ -n ${SPARKLE_KEY_FILE:-} ]] && key_args=(--ed-key-file "$SPARKLE_KEY_FILE")
"$tools[1]/generate_appcast" "${key_args[@]}" --embed-release-notes --download-url-prefix "$prefix" build/updates
echo "1. Zip à publier dans $prefix : $PWD/build/updates/EZAIStatus-$version.zip"
echo "2. Puis appcast à publier à $feed : $PWD/build/updates/appcast.xml"
