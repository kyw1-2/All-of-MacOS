# Oracle → GitHub Actions → macOS Release

GitHub repository: `kyw1-2/All-of-MacOS` (private).

## Architecture

- Every trusted `main` push that modifies the application/build inputs: GitHub Actions macOS 15 worker tests, imports the existing AOM Dev identity from Secrets, builds, verifies app and XPC signatures, creates a DMG and publishes a GitHub **Latest** release.
- An Oracle `workflow_dispatch` request can trigger exactly the same macOS job without requiring the MacBook.
- Pull requests continue to use the ad-hoc test workflow and **never** receive the signing identity.
- Old versions remain archived; `1.0.1` is retired and will not be published.
- Only the DMG is uploaded. SHA-256 is recorded in release notes and GitHub's asset digest.
- No private certificate, GitHub token, keychain or P12 file is committed to this repository or copied to Oracle.

## One-time signing setup on the Mac (requires owner's action)

GitHub's private macOS runner cannot access the original MacBook's login Keychain. The original identity has to be exported *once*. Do not share the certificate/passphrase in chat.

1. Open **Keychain Access** → **login** → **My Certificates**. Select only the existing **AOM Dev** signing identity together with its private key.
2. **File → Export Items…** → PKCS #12 (`.p12`), protected by a unique strong password. If export is unavailable, do not attempt to work around macOS keychain policy.
3. In Finder, open `~/All-of-MacOS/scripts/setup-actions-signing.command` (a Desktop shortcut may also be available). Choose the exported `.p12` and enter its password in the hidden native dialog.
4. This local helper uploads `AOM_DEV_P12_BASE64` and `AOM_DEV_P12_PASSWORD` *directly* to this repository's GitHub Actions Secrets, sets repository variable `AOM_SIGNING_READY=true`, and dispatches a release verification run.
5. Check [GitHub Actions](https://github.com/kyw1-2/All-of-MacOS/actions/workflows/release.yml). Remove or protect the exported `.p12` after verifying, because it contains the private signing key.

The assistant cannot export/copy the keychain private key on the user's behalf through the remote control connection; no key material has been transferred. Until `AOM_SIGNING_READY=true`, the signed workflow is safely skipped and the previous ad-hoc CI continues on main pushes.

## Oracle manual trigger (optional)

Oracle command installed: `/home/ubuntu/.local/bin/aom-release`

The GitHub `main` push trigger needs no Oracle token. For **Oracle-initiated manual releases** when the MacBook is off, create a **fine-grained personal access token** for this repository with *Actions: Read and write* and *Metadata: Read*. Save it as `/home/ubuntu/.config/aom-release/dispatch-token` with filesystem permission `0600`, directly on Oracle, not in this repository.

- `aom-release trigger`: request an on-demand macOS signing/build/release job on GitHub.
- `aom-release status`: list recent executions.

The Oracle trigger runs without storing the signing certificate or private key. Do not reuse a broad GitHub account token if a restricted repository token can be created.

## Important constraints

- This certificate is local self-signed **AOM Dev**, not Apple Developer ID. Neither the app nor DMG is Apple notarized. Gatekeeper approval may be required.
- **Continuous delivery** means automatic Release publication. Automatic installation into `/Applications` on an offline Mac is a separate workflow and is not enabled here. The existing in-app update checker is disabled and private GitHub download URLs require authentication.
- A signed release is published only after full Swift tests, app/XPC signature validation and DMG integrity checks. An outdated queued run is not promoted as Latest.
- GitHub-hosted macOS runners consume billed Actions minutes on private repositories; avoid unnecessary rebuilds. Only relevant application/build input paths trigger a signed run; the ad-hoc job is skipped on main once signing is enabled.
