#!/bin/bash
# Run locally on the Mac AFTER exporting only the 'AOM Dev' identity from
# Keychain Access as a password-protected PKCS#12 (.p12) file.
# Signing credentials go directly to GitHub Actions Secrets, never to Oracle.
set -euo pipefail
set +x
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
REPO="kyw1-2/All-of-MacOS"
log() { printf '\n%s\n' "$*"; }
fail() { log "ERROR: $*"; osascript -e 'display dialog "AOM signing setup failed. Review Terminal for details." buttons {"OK"} default button 1' >/dev/null; exit 1; }
command -v gh >/dev/null || fail "GitHub CLI not installed"
gh auth status -h github.com >/dev/null 2>&1 || fail "GitHub CLI not authenticated"
log "Select the password-protected .p12 exported from Keychain Access for AOM Dev only."
file="$(osascript -e 'POSIX path of (choose file with prompt "Select AOM Dev code signing identity (.p12)")')" || exit 2
[[ "$file" == *.p12 ]] && [[ -s "$file" ]] || fail "You must choose a .p12 file"
password="$(osascript -e 'text returned of (display dialog "Password protecting the AOM Dev .p12" default answer "" with hidden answer buttons {"Cancel","OK"} default button "OK")')" || exit 2
[ -n "$password" ] || fail "Empty .p12 password"
# Verify that selected file can be decrypted without exposing certificate material.
if ! /usr/bin/openssl pkcs12 -in "$file" -info -noout -passin fd:3 3<<<"$password" >/dev/null 2>&1; then
  fail "Cannot open .p12 with that password"
fi
log "Uploading encrypted signing identity to repository Actions Secrets..."
base64 -i "$file" | gh secret set AOM_DEV_P12_BASE64 --repo "$REPO"
printf '%s' "$password" | gh secret set AOM_DEV_P12_PASSWORD --repo "$REPO"
unset password
gh variable set AOM_SIGNING_READY --repo "$REPO" --body true
log "Enabled signed GitHub Actions builds. Dispatching verification release..."
gh workflow run release.yml --repo "$REPO" --ref main
log "DONE. No .p12 was copied to Oracle."
log "Keep the original certificate in Keychain Access; move the exported .p12 to an encrypted backup or securely erase it."
log "GitHub Actions: https://github.com/$REPO/actions/workflows/release.yml"
osascript -e 'display dialog "AOM signing enabled. GitHub release workflow started. Check the GitHub Actions page for results." buttons {"OK"} default button 1' >/dev/null
