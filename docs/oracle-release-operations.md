# Oracle-only AOM release control: reality and checklist

Updated 2026-10-14. Private repo: `kyw1-2/All-of-MacOS`.

## Verified

- Oracle Linux ARM: source checkout with full Git history at `/data/academic-workspace/projects/all-of-macos`; verified and fast-forwarded to AOM 1.0.13 source commit `262397315ad515637c1fd0d8849b8610ed108a5e` via integrity-checked Git bundle on 2026-10-14.
- Oracle previously cached AOM 1.0.11 **already signed** DMG and verified its SHA-256 manifest at `/data/academic-workspace/projects/aom-release-cache`.
- Oracle tools: `aomctl` for local source/Git commands, `aom-release` for authenticated Actions dispatch/status, `aom-publish-presigned` for already signed binary uploads.
- On 2026-10-14, a fresh manually dispatched Linux Actions script-check run [#38570042862](https://github.com/kyw1-2/All-of-MacOS/actions/runs/38570042862) was **blocked before starting** by GitHub Billing & plans (recent failed payments or spending limit). Billing remains an external blocker, not a compile error.
- Repository variable `AOM_SIGNING_READY=false` and repository Actions Secrets list was empty as of 2026-10-14. Do not set signing ready until both secret values have been provisioned.
- GitHub's latest AOM 1.0.13 DMG already exists, but was built/signed locally; it does not prove successful CI release provenance.
- The original Mac AOM Dev signing key **has not** been exported or copied to Oracle. The remote-control security gate blocked attempts to export/transfer keychain credentials. This must not be silently bypassed.

## Workflow once prerequisites are provisioned

```text
Oracle: edit source -> aomctl commit "message" path... -> aomctl push
          |
          v (trusted main push to paths listed in release.yml)
GitHub Actions macos-15: swift test -> import AOM Dev P12 from GitHub Secrets
          -> build App/XPC -> codesign verify -> hdiutil verify
          -> GitHub latest signed DMG Release
```

The Oracle server **cannot** build SwiftUI/AppKit or use Xcode; copying a
signing private key does not change this. Newly compiled signed DMGs require
a running macOS machine: a repaired GitHub-hosted macOS runner, another
licensed macOS CI provider, or a dedicated Mac.

## One-time activation (requires repository owner; never paste secrets in chat)

1. GitHub [Billing & plans](https://github.com/settings/billing) — resolve Actions execution block. For private repositories macOS runner minutes can be billed; impose a sensible spending limit.
2. Git write auth on Oracle: generate a dedicated *repository-only* SSH Ed25519 deploy key on Oracle, register **only the public key** in [Deploy keys](https://github.com/kyw1-2/All-of-MacOS/settings/keys) with write enabled, and pin GitHub's verified SSH host key. Keep the private key mode 0600 under the ubuntu account, never in Git, and restrict `~/.ssh/config` to use that identity only for this repository. Do not reuse a personal Mac login or an account-wide GitHub token.
3. On the Mac, use Keychain Access to export the **existing AOM Dev code-signing identity AND its private key** as password-protected `.p12`. The self-signed identity is not Apple Developer ID, and builds are **not notarized**. GitHub CLI 2.102.0 was installed to `~/.local/bin/gh` on 2026-10-14, and Mac GH login is verified; run `scripts/setup-actions-signing.command` after selecting the `.p12` in the Mac GUI. This uploads the signing material directly to GitHub repository Actions Secrets `AOM_DEV_P12_BASE64`/`AOM_DEV_P12_PASSWORD` and sets `AOM_SIGNING_READY=true`. **Do not copy the private key to Oracle.**
4. For optional **manual** dispatch from Oracle: create a repository-only fine-grained token with Actions write (and Metadata read) and store as `/home/ubuntu/.config/aom-release/dispatch-token` mode 0600. Without this, main pushes still auto-run the release workflow after step 3.
5. Run `aomctl doctor`, `aomctl status`, `aomctl sync`, then make a test-only change on a separate branch or a reviewed main change. Verify the pipeline runs, code signing app/XPC and DMG checksum before trusting an unattended release.

## Commands

- `aomctl doctor`: test local tools and GitHub remote access; never prints tokens.
- `aomctl status`: branch and HEAD.
- `aomctl sync`: fetch + fast-forward; refuses dirty working trees.
- `aomctl commit "fix(ui): example" AllOfMacOS/...`: commits **only named paths**.
- `aomctl push`: non-force push of local clean main; no history rewriting.
- `aomctl release`: push main and show CI URL; **does not declare a binary shipped** before CI success.
- `aom-release trigger` / `aom-release status`: on-demand CI dispatch/status with scoped token.
- `aomctl verify-cache`: validate the previously signed release artifact manifest.
- `aom-publish-presigned publish ...`: separately publish a previously signed, checked artifact using a scoped REST token; no Linux signing/building.

## Controls

- Do not make private repo public to evade billing.
- Never put .p12, .pem, GitHub tokens, SSH private keys or Mac keychain exports in repository or command logs.
- CI secrets are confined to trusted main release job, not pull requests.
- Existing `release.yml` will skip signing unless variable + secrets are configured.
- GitHub-hosted runner execution remains impossible **until** GitHub billing is corrected, independent of Oracle setup. Do not describe any partially configured path as a tested Mac-off build.
