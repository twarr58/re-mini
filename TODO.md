# TODO

## Distribution

- [ ] **Homebrew cask** in a separate tap (`twarr58/homebrew-tap`), so people can install with
      `brew install --cask twarr58/tap/remini`.
  - Cask `Casks/remini.rb` points at the release zip and its sha256, with
    `depends_on macos: ">= :tahoe"` and `depends_on arch: :arm64`.
  - The Publish job updates the version and sha256 in the tap after each release. It needs a token
    (fine-grained PAT or GitHub App) that can push to the tap repo, stored as a repository secret.
  - Gatekeeper: the app is only ad-hoc signed, so the cask needs a caveat about the quarantine attribute,
    or Developer ID signing and notarization (see below).
- [ ] Developer ID signing and notarization, so Gatekeeper accepts downloads without `xattr`.
      Requires a paid Apple Developer account.
- [ ] Universal binary (arm64 + x86_64), if Intel Macs on macOS 26 should be supported.

## App

- [ ] **"Liked from ReMini" playlist without the Web API**, so it works for everyone without setting up a Spotify app.
  ReMini would open the player's "Add to playlist" menu in the hidden web view and click the playlist by name,
  creating the playlist first if it is missing.
  - First, collect the current DOM: add a *Debug → Copy player HTML* menu item that copies the now-playing widget
    and the open "Add to playlist" menu to the clipboard. Then write the selectors from it.
  - Fragile like the other DOM controls. Fall back to Liked Songs when a selector is not found.
