<p align="center"><img src="docs/icon.png" width="128" alt="ReMini icon"></p>

<h1 align="center">ReMini</h1>

<p align="center">A small, native macOS glass mini player for the Spotify web player.</p>

> **Unofficial.** This is a personal project. It is not affiliated with, endorsed by, or connected to Spotify AB.
> "Spotify" is a trademark of Spotify AB. You need your own Spotify account, and use is subject to Spotify's Terms of Use.

<p align="center">
  <img src="docs/mini.png" width="340" alt="Mini player">
  &nbsp;&nbsp;
  <img src="docs/tiny.png" width="140" alt="Tiny player">
</p>
<p align="center"><sub>Mini and Tiny modes. Screenshots use a made-up demo track and cover.</sub></p>

## Motivation

On my work machine, company policy blocks the Spotify desktop app. The web player works, but it lives in a browser tab that is always buried under a pile of other windows and tabs. Just pausing a song or seeing what's playing means digging for that tab.

So ReMini wraps the web player in a small, native macOS window that stays on top. It shows what's playing in the menu bar and gives you play, skip, and like without hunting for a tab. When you need to search or browse, it expands to the full web player.

## Features

- **Three sizes.** Switch with <kbd>⌘1</kbd> / <kbd>⌘2</kbd> / <kbd>⌘3</kbd>, the View menu, or the menu bar menu:
  - **Tiny** (140×140): only the cover. Click it to play or pause. Dislike and like float in the corners.
  - **Mini** (340×500): cover, title, artist, progress, and controls (👎 ⏮ ⏯ ⏭ ♥).
  - **Full**: the complete Spotify web player for browsing, search, and playlists. It can be resized and remembers its size.
- **Liquid Glass look.** It uses `NSGlassEffectView`, and the glass is tinted with the average colour of the current cover.
- **Menu bar item.**
  - The bar shows the current track. Long titles scroll smoothly.
  - Its menu works like Control Center's Now Playing: cover, title, artist, and a row of buttons (👎 ⏮ ⏯ ⏭ ♥). The buttons act without closing the menu.
- **Standard window.** It has normal close, minimize, and zoom buttons (green toggles Mini ↔ Full) and floats above other windows.
  - **Close** hides the window and the music keeps playing. Bring it back with the Dock icon or **Show Player**.
- **Smart resizing.** When you switch sizes, the window grows away from the nearer screen edges. Switching back puts it exactly where it was.
- **Content zoom** for the full player: <kbd>⌘=</kbd> / <kbd>⌘−</kbd> / <kbd>⌘0</kbd>. The zoom is remembered.
- **Standard login.** You log in on Spotify's own login page, and the session persists between launches.

## Requirements

- macOS 26 (Tahoe) or later, because the app uses `NSGlassEffectView`.
- Xcode Command Line Tools for `swiftc`. You don't need an Xcode project.
- A Spotify account. Free works, Premium removes ads.

## Build & run

```sh
./build.sh
open ReMini.app
```

`build.sh` compiles `main.swift`, creates the `.app` bundle, and ad-hoc signs it. Copy `ReMini.app` to `/Applications` if you want to keep it.

To change the icon, run `swift make-icon.swift` and then rebuild. To draw the hand-written "RE" over your own base image, use `swift make-icon.swift base.png`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| <kbd>⌘1</kbd> / <kbd>⌘2</kbd> / <kbd>⌘3</kbd> | Tiny / Mini / Full |
| <kbd>⌘=</kbd> / <kbd>⌘−</kbd> / <kbd>⌘0</kbd> | Zoom in / out / reset, in the full player |
| <kbd>⌘R</kbd> | Reload the web player |
| <kbd>⌘M</kbd> / <kbd>⌘W</kbd> / <kbd>⌘Q</kbd> | Minimize / close (playback continues) / quit |

On keyboard layouts without digits on the top row, macOS shows these shortcuts with that layout's characters. On a Czech layout, for example, ⌘1/2/3 appear as ⌘+ / ⌘ě / ⌘š. The physical keys are the same.

## How it works

The app is a single Swift file (`main.swift`) with no third-party dependencies.

- **Playback engine.** A `WKWebView` runs `open.spotify.com`. In Tiny and Mini modes it stays in the window with `alphaValue = 0`, not `isHidden`. WebKit suspends hidden views, and that would stall playback.
- **Now-playing bridge.** A small injected script checks the page once a second and reports to the app only when something changes.
  - Title, artist, and cover come from `navigator.mediaSession`, with the player bar as a fallback while paused.
  - Progress and like state come from the player's `data-testid` attributes.
- **Controls.** The native buttons click the real buttons in the web player, so queue, shuffle, and Spotify Connect behave as they do in a browser.

## Known limitations

- **Selectors can break.** The app depends on Spotify's web player DOM (`data-testid`). If Spotify renames those attributes, some controls stop working until the selectors in `bridgeJS` and `click(...)` are updated.
- **Dislike = skip.** Spotify has no general "dislike" for tracks, so 👎 skips to the next one.
- **Un-liking** a track opens Spotify's own "add to playlist" dialog, so the app switches to Full mode for it.
- **No seeking** from the progress bar in Mini mode.
- **Browser identity.** The web player reports itself as Safari through its user agent.

## Files

| File | Purpose |
|---|---|
| `main.swift` | The whole app |
| `build.sh` | Build and bundle script |
| `make-icon.swift` | Renders `AppIcon.icns` |
| `AppIcon.icns` | App icon (original artwork) |
| `docs/` | README images |
