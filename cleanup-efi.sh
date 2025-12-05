#!/usr/bin/env bash
set -euo pipefail

TARGET="/boot/efi/EFI/Microsoft/Boot"

# Sanity checks
if [[ ! -d "$TARGET" ]]; then
  echo "Error: Microsoft Boot folder not found at $TARGET"
  exit 1
fi

if ! mountpoint -q /boot/efi; then
  echo "Error: /boot/efi is not mounted"
  exit 1
fi

echo "Checking $TARGET for language bloat..."

BEFORE=$(du -sh "$TARGET" | cut -f1)

# Grab directories matching the pattern xx-XX, excluding EN-US and EN-GB
CANDIDATES=$(find "$TARGET" \
  -mindepth 1 -maxdepth 1 -type d \
  -regex '.*/[a-z][a-z]-[A-Z][A-Z]' \
  ! -name 'en-US' ! -name 'en-GB')

if [[ -z "$CANDIDATES" ]]; then
  echo "No non-English language folders found."
  exit 0
fi

echo "The following language directories will be deleted:"
echo "$CANDIDATES"
read -rp "Proceed? [y/N] " REPLY
[[ "$REPLY" =~ ^[Yy]$ ]] || exit 0

# Delete them
echo "Deleting..."
echo "$CANDIDATES" | xargs -r rm -rfv

echo "--------------------------------"
echo "Cleanup Complete."
echo "Size before: $BEFORE"
echo "Size now:    $(du -sh "$TARGET" | cut -f1)"
