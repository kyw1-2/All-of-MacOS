#!/bin/bash
# Print one validated signing selector for both the application and XPC helper.
set -euo pipefail

REQUESTED="${1:-${ALLOFMACOS_SIGN_ID:-AOM Dev}}"
if [ "$REQUESTED" = "-" ]; then
    printf '%s\n' '-'
    exit 0
fi
if [ "$REQUESTED" != "AOM Dev" ] && ! [[ "$REQUESTED" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "ERROR: Expected AOM Dev, its valid SHA-1 identity, or - (CI test only)." >&2
    exit 1
fi

IDENTITIES="$(security find-identity -v -p codesigning)"
MATCHES="$(printf '%s\n' "$IDENTITIES" |
    sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) "AOM Dev"$/\1/p' |
    tr '[:lower:]' '[:upper:]' | sort -u)"

if [ "$REQUESTED" != "AOM Dev" ]; then
    REQUESTED="$(printf '%s' "$REQUESTED" | tr '[:lower:]' '[:upper:]')"
    while IFS= read -r IDENTITY; do
        if [ "$IDENTITY" = "$REQUESTED" ]; then
            printf '%s\n' "$IDENTITY"
            exit 0
        fi
    done <<< "$MATCHES"
    echo "ERROR: The requested SHA-1 is not a valid AOM Dev Code Signing identity." >&2
    exit 1
fi

if [ -z "$MATCHES" ]; then
    echo "ERROR: No valid AOM Dev Code Signing identity. Check its private key and Code Signing trust in Keychain Access." >&2
    exit 1
fi
if [[ "$MATCHES" = *$'\n'* ]]; then
    echo "ERROR: Multiple valid AOM Dev identities. Set ALLOFMACOS_SIGN_ID to the intended SHA-1 from security find-identity -v -p codesigning." >&2
    exit 1
fi
printf '%s\n' "$MATCHES"
