#!/bin/zsh
# Notarise et agrafe build/EZAIStatus.app, puis produit build/EZAIStatus.zip à distribuer.
# Prérequis (une seule fois) : un profil notarytool dans le trousseau, par exemple
#   xcrun notarytool store-credentials EZAIStatus --apple-id <id> --team-id <équipe>
set -euo pipefail
cd "${0:A:h}/.."

profile=${NOTARY_PROFILE:-EZAIStatus}
scripts/build-app.sh --release

ditto -c -k --keepParent build/EZAIStatus.app build/EZAIStatus-notarize.zip
xcrun notarytool submit build/EZAIStatus-notarize.zip --keychain-profile "$profile" --wait
xcrun stapler staple build/EZAIStatus.app
rm build/EZAIStatus-notarize.zip
ditto -c -k --keepParent build/EZAIStatus.app build/EZAIStatus.zip
spctl --assess --type execute --verbose build/EZAIStatus.app
echo "Prêt à distribuer : $PWD/build/EZAIStatus.zip"
