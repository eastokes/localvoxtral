# Building from source

Requires a Mac with Apple Silicon, macOS 15+, and Xcode (on Xcode 26+ the
Metal compiler is a separate one-time download:
`xcodebuild -downloadComponent MetalToolchain`).

```bash
./scripts/package_app.sh release
open ./dist/localvoxtral.app
```

For development:

```bash
swift build        # app package (never compiles the MLX C++ core)
swift test         # tier-0 unit suite (500+ tests)
```

The MLX helpers (`PolishHelper/`, `SpeechHelper/` — the bundled
`localvoxtral-polishd` / `localvoxtral-speechd` engines) are separate SwiftPM
packages. `swift build` of a helper compiles but cannot produce working Metal
kernels — only the xcodebuild lane inside `package_app.sh` can, which is why
"build the app" is `package_app.sh` and not `swift build`.

## Stable local code signing

Accessibility permission is tied to the app's designated code requirement.
An ad-hoc signature changes when the app is rebuilt, so macOS can leave a
checked but stale Accessibility row while `AXIsProcessTrusted()` returns false.
Local installs therefore require a stable signing identity.

Create one once in **Keychain Access → Certificate Assistant → Create a
Certificate…**:

- Name: `localvoxtral-dev`
- Identity Type: **Self Signed Root**
- Certificate Type: **Code Signing**
- Keychain: **login**

After creation, open the certificate, expand **Trust**, set **Code Signing**
to **Always Trust**, close the window, and authenticate. Confirm the certificate
appears under **My Certificates** with an attached private key.

Confirm it is available (do not use `sudo`; root has a different keychain search list):

```bash
security find-identity -v -p codesigning | grep 'localvoxtral-dev'
```

Quit any running copy of localvoxtral, then package and install with the stable identity:

```bash
mise run install-local
```

`install-local` depends on `package-local`, so one command builds, signs, and
installs the app. The install task refuses both ad-hoc bundles and replacement
while the app is running, preventing a stale process or signature from
confusing TCC.

`package-local` defaults to `localvoxtral-dev` and refuses to fall back to
ad-hoc signing. To use another existing Code Signing identity:

```bash
LOCALVOXTRAL_CODESIGN_IDENTITY="Your Identity" mise run install-local
```

After switching from an old ad-hoc build, remove or reset the stale
Accessibility entry, quit and reopen the newly signed app, and grant it once.
Future builds signed by the same identity retain that grant.

Working from a non-Mac machine, wanting to run the integration or eval
lanes, or contributing a change? See [CONTRIBUTING.md](../CONTRIBUTING.md)
and the agent guide ([AGENTS.md](../AGENTS.md)) — the latter documents the
remote-build workflow and the full test-tier matrix.
