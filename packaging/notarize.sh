#!/usr/bin/env bash
#
# Soumet le .pkg construit par build-installer.sh au service de notarisation
# Apple, attend le verdict, puis "staple" le ticket dans le .pkg (et dans la
# .app) pour que Gatekeeper accepte le bundle même hors-ligne.
#
# Setup nécessaire une seule fois :
#   1. Crée un app-specific password sur https://appleid.apple.com/account/manage
#   2. Stocke-le dans le trousseau :
#        xcrun notarytool store-credentials wacomd-notary \
#            --apple-id "ton@apple.id" \
#            --team-id  "4U3987KC72" \
#            --password "xxxx-xxxx-xxxx-xxxx"
#   3. Lance ./packaging/notarize.sh
#
# Le script suppose que build-installer.sh a déjà produit un .pkg signé dans
# build/.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_DIR/packaging/signing.env"

PKG="$(ls -t "$REPO_DIR/build/"wacomd-*.pkg 2>/dev/null | head -1)"
APP="$REPO_DIR/build/Wacomd Config.app"

if [ -z "$PKG" ] || [ ! -f "$PKG" ]; then
    echo "✗ Aucun .pkg trouvé dans build/. Lance d'abord ./packaging/build-installer.sh"
    exit 1
fi

echo "==> Pkg : $PKG"
echo "==> App : $APP"
echo "==> Profil notarytool : $NOTARY_PROFILE"

# ============================================================================
# 1. Submit le .pkg (notarisation au niveau du package distribué)
# ============================================================================
echo
echo "==> Soumission à Apple (peut durer 3-15 minutes)…"
SUBMIT_LOG="$REPO_DIR/build/notarize-submit.log"
xcrun notarytool submit "$PKG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json 2>&1 | tee "$SUBMIT_LOG"

STATUS=$(grep -E '"status"' "$SUBMIT_LOG" | tail -1 | sed -E 's/.*"status": *"([^"]+)".*/\1/')
SUBMISSION_ID=$(grep -E '"id"' "$SUBMIT_LOG" | head -1 | sed -E 's/.*"id": *"([^"]+)".*/\1/')

echo
echo "==> Status retourné : $STATUS  (submission $SUBMISSION_ID)"
if [ "$STATUS" != "Accepted" ]; then
    echo "✗ Notarisation refusée. Récupère le log d'Apple :"
    echo "  xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE"
    exit 1
fi

# ============================================================================
# 2. Staple le ticket de notarisation dans la .pkg et dans la .app
# ============================================================================
echo
echo "==> Stapler le ticket dans le .pkg"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

if [ -d "$APP" ]; then
    echo
    echo "==> Stapler le ticket dans la .app"
    xcrun stapler staple "$APP" 2>/dev/null || \
        echo "(la .app n'a pas été soumise indépendamment ; ticket récupéré via le .pkg lors de la 1re ouverture)"
fi

echo
echo "✓ $PKG est signé, notarisé et staplé. Prêt pour distribution publique."
