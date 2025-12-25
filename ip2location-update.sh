#!/bin/bash

# -------- CONFIGURATION ---------
SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LOG_FILE="${SCRIPT_DIR}/ip2loc-db-update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }

ZIP_FILE=$(mktemp)

TEMP_TARGET="" # Initialize variable

cleanup() {
    if [ -f "$ZIP_FILE" ]; then rm -f "$ZIP_FILE"; fi
    if [ -n "$TEMP_TARGET" ] && [ -f "$TEMP_TARGET" ]; then rm -f "$TEMP_TARGET"; fi;
}

trap cleanup EXIT

ENV_FILE="${SCRIPT_DIR}/.env_ip2db"
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    log "⚠️ Warning: $ENV_FILE not found. Relying on system environment variables or defaults."
fi

# Define variables using env values OR defaults
TOKEN="${IP2_TOKEN:-token_in_env}"
CODE="${DB_CODE:-DB11LITEBINIPV6}"
DEST_DIR="${DEST_DIR:-/home/alis/ip-service/ip_dbs}"
TARGET_FILE="${TARGET_FILE:-IP2LOCATION-LITE-DB11.IPV6.BIN}"
COMPOSE_FILE="${COMPOSE_FILE:-/home/alis/ip-service/docker-compose.yml}"
SERVICE_NAME="${SERVICE_NAME:-ip-echo}"
# -----------------------------------

# Ensure destination directory exists
mkdir -p "$DEST_DIR"

log "⬇️  Starting update check for code: $CODE..."

# 1. Download to the secure temp file
wget -q -O "$ZIP_FILE" "https://www.ip2location.com/download?token=$TOKEN&file=$CODE"

# 2. Check if the zip is valid
if ! unzip -t "$ZIP_FILE" > /dev/null 2>&1; then
    FILE_SIZE=$(du -h "$ZIP_FILE" | cut -f1)
    log "❌ Error: Downloaded file is not a valid ZIP."
    log "ℹ️  Downloaded File Size: $FILE_SIZE"
    log "ℹ️  Possible causes: Daily Limit Exceeded (file is HTML) or Token Invalid."
    exit 1
fi

# 3. Compare Checksums
NEW_MD5=$(unzip -p "$ZIP_FILE" "*.BIN" | md5sum | awk '{print $1}')

if [ -f "$DEST_DIR/$TARGET_FILE" ]; then
    OLD_MD5=$(md5sum "$DEST_DIR/$TARGET_FILE" | awk '{print $1}')
else
    OLD_MD5="none"
fi

log "ℹ️  New MD5: $NEW_MD5"
log "ℹ️  Old MD5: $OLD_MD5"

# 4. Decide to Update or Not
if [ "$NEW_MD5" != "$OLD_MD5" ]; then
    log "✅ Update detected! Installing new database..."

    TEMP_TARGET="$DEST_DIR/${TARGET_FILE}.tmp"

    if unzip -p "$ZIP_FILE" "*.BIN" > "$TEMP_TARGET"; then
        mv "$TEMP_TARGET" "$DEST_DIR/$TARGET_FILE"
        TEMP_TARGET=""

        # Restart the container
        log "🚀 Restarting Docker container..."
        if docker compose -f "$COMPOSE_FILE" restart "$SERVICE_NAME"; then
             log "🎉 Success: Database updated and service restarted."
        else
             log "⚠️ Warning: Database updated, but Docker restart failed."
        fi
    else
        log "❌ Error: Failed to extract to temp file."
        exit 1
    fi
else
    log "👍 No update needed. Database is already current."
fi
