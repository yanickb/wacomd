#!/usr/bin/env bash
#
# Deploy the wacomd landing page to app.thinkspark.eu.
#
# Usage :
#   ./packaging/deploy.sh                # rsync via SSH (default)
#   ./packaging/deploy.sh --dry-run      # show what would be uploaded
#
# Configure DEPLOY_USER / DEPLOY_HOST / DEPLOY_PATH below (or override
# via env vars) before running.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_DIR/web/wacom_PTH-405_Driver/"

DEPLOY_USER="${DEPLOY_USER:-thinkspark}"
DEPLOY_HOST="${DEPLOY_HOST:-app.thinkspark.eu}"
DEPLOY_PATH="${DEPLOY_PATH:-/var/www/app.thinkspark.eu/wacom_PTH-405_Driver/}"

DRY_RUN=""
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN="--dry-run"
    echo "==> DRY RUN — nothing will be uploaded"
fi

echo "==> Source : $SRC"
echo "==> Target : $DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PATH"

# Refresh the .pkg in case the daemon was just rebuilt.
if [ -f "$REPO_DIR/build/wacomd-0.8.4.pkg" ]; then
    echo "==> Updating wacomd-latest.pkg from build/"
    cp "$REPO_DIR/build/wacomd-0.8.4.pkg" "$SRC/wacomd-latest.pkg"
fi

echo "==> rsync"
rsync -avz --delete $DRY_RUN \
    --exclude '.htaccess.bak' \
    -e ssh \
    "$SRC" \
    "$DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PATH"

if [ -z "$DRY_RUN" ]; then
    echo
    echo "✓ Deployed."
    echo "  https://app.thinkspark.eu/wacom_PTH-405_Driver/"
    echo "  https://app.thinkspark.eu/wacom_PTH-405_Driver/index.en.html"
fi
