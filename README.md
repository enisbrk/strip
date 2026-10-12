# Strip

A scrolling, tiling window manager for macOS 13+. This repository holds the website (root) and the app (`app/`).

```
index.html, assets/   website (static, served by GitHub Pages)
appcast.xml           Sparkle update feed — https://enisbrk.github.io/strip/appcast.xml
app/                  Swift package: Sources, Tests, Resources, scripts
```

## Develop

```bash
cd app
swift test
scripts/bundle.sh debug        # build/Strip.app
```

Website preview: `python3 -m http.server` in the repository root.

## One-time release setup

1. **Developer ID certificate** — Xcode → Settings → Accounts → Manage Certificates → `+` → *Developer ID Application*.
2. **Notarization credentials** — create an app-specific password at appleid.apple.com, then
   `xcrun notarytool store-credentials strip-notary --apple-id <apple-id> --team-id 2XYM3358P5 --password <app-specific-password>`
3. **Sparkle key** — the EdDSA private key that signs updates is in the login keychain (created with
   `app/.build/artifacts/sparkle/Sparkle/bin/generate_keys`). Back it up with `generate_keys -x strip-sparkle.key`
   and keep it safe: without it, installed copies can't be updated. The public key is `SUPublicEDKey` in `app/Resources/Info.plist`.
4. **GitHub** — create the `enisbrk/strip` repository and enable Pages (Settings → Pages → Deploy from branch `main`, `/`).

## Release a version

```bash
cd app
scripts/bump-version.sh 1.1.0
NOTARY_PROFILE=strip-notary scripts/release.sh "What changed in this version"
git -C .. add -A && git -C .. commit -m "Release 1.1.0" && git -C .. push
```

`release.sh` builds a universal app, signs it (and Sparkle) with Developer ID and hardened runtime, notarizes and staples
the DMG, adds the version to `appcast.xml`, updates the version on the website and creates the GitHub release
(`Strip-<version>.dmg` plus `Strip.dmg` for the website's “latest” link). Installed copies check the feed daily,
download in the background and install on the next restart.
