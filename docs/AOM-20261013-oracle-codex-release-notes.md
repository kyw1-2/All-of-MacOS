# AOM Oracle Codex follow-up release candidate (2026-10-13)

**Status: SOURCE-ONLY PRERELEASE / NOT A SIGNED APP BINARY**

- Repository: `kyw1-2/All-of-MacOS`.
- Source branch: `release/aom-studio-cursor-20261013`.
- The source snapshot includes the independently implemented Studio Mode
  foundation and the new Oracle Codex evidence follow-up.
- Original Oracle evidence: `/data/academic-workspace/projects/cleanshotx-rea-20261013/FOLLOWUP-RESIZE-OVERLAY-20261013.md`.
- Imported evidence: `docs/cleanshot-501-oracle-codex-resize-overlay-evidence-followup.md`.
- The Codex document was an investigation only. It expressly reports that it
  did **not** change the AOM application source.
- New AOM code changes based on that report: Quick Access Option inversion of
  successful-drag close preference and save-location prompt preference, with
  regression cases for canceled drags and both saved configurations.
- Reference analysis identifies 15 Interface Builder documents, 1,316 NIB
  nodes, and 706 edges. This is static binary evidence, not macOS runtime
  equivalence or recovered proprietary source.
- Mac remote host is offline. GitHub Actions macOS 14/15 jobs are failing
  *before* runner allocation, with `runner_id=0` and zero executed steps.
  Latest source has not passed Swift compilation, tests, signing, install or
  UI A/B playback.
- This source-only prerelease **contains no signed DMG**. In particular, any
  older `bc78ec22` artifact is not the current release source or latest
  Studio binary. Do not overwrite the existing latest stable
  `aom-dev-v1.0.7-b2026101301-b31fa5b6fcce`.
- No CleanShot X proprietary binary, DMG, NIB assets, source code, or raw
  extracted content is included in the GitHub repository.

## Runtime verification still required

1. Restore macOS runner availability or connect a real Mac with Xcode.
2. Run `swift test -j 2` and `./build-and-sign.sh`.
3. Inspect screenshots/drag modifiers, save-cancel semantics, annotation Resize
   and Flatten, cursor sidecars and rendered studio MP4s on macOS.
4. Verify main and XPC signatures use the independent `AOM Dev` identity.
5. Publish a **separate binary release** only after the new DMG passes tests
   and `hdiutil verify`.

## Links

- [Oracle evidence follow-up](cleanshot-501-oracle-codex-resize-overlay-evidence-followup.md)
- [REA implementation ledger](cleanshot-501-rea-implementation-ledger.md)
- [Release candidate PR](https://github.com/kyw1-2/All-of-MacOS/pull/4)
