# All of MacOS — standalone identifiers

| Layer | Current value |
|---|---|
| GitHub repository | `kyw1-2/All-of-MacOS` |
| Swift package, executable and source module | `AllOfMacOS` |
| Swift tests | `AllOfMacOSTests` |
| Application display name | `All of MacOS` |
| Application identifier | `com.kyw.allofmacos` |
| ScriptRunner XPC identifier | `com.kyw.allofmacos.ScriptRunner` |
| Application preference key prefix | `AOM` |
| User data | `~/Library/Application Support/AllOfMacOS` |
| Built app | `build/All of MacOS.app` |
| DMG | `All-of-MacOS.dmg` |
| Commit identity | `Kim Yongwoo` |

The new source module, build configuration and app data directory are now separate from the original application.

## Signing

Use the authorized local developer signing certificate via the `ALLOFMACOS_SIGN_ID` environment setting when building a local distribution. With no certificate specified, the build creates an ad-hoc testing signature. Certificate naming is separate from application bundle identifiers.

## Provenance

The source was derived from a prior application. Original project names can remain in `SOURCE_PROVENANCE.md` and archived `docs/` so the original authorship record remains accurate. These references are not active bundle names or build targets. Check reuse/distribution rights before publishing.
