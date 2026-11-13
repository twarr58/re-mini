import AppKit
import WebKit

enum Mode { case tiny, mini, full }


// Glass background: the window is movable by background, buttons and the web view handle their own clicks.
final class DragArea: NSView {
    let grabber = CALayer()   // layer, not a view: nothing to steal hit-testing

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grabber.backgroundColor = NSColor.labelColor.withAlphaComponent(0.3).cgColor
        grabber.cornerRadius = 2.5
        layer?.addSublayer(grabber)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        grabber.frame = NSRect(x: bounds.midX - 22, y: bounds.maxY - 16, width: 44, height: 5)
        grabber.isHidden = bounds.width < 200   // tiny mode: would collide with the traffic lights
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

// Mini player container: buttons get clicks; anything else is caught here (shielding the invisible web view
// underneath). It's non-opaque, so mouseDownCanMoveWindow = true and the glass stays draggable.
final class PassThrough: NSView {
    override func hitTest(_ p: NSPoint) -> NSView? { let v = super.hitTest(p); return v == nil || v is NSButton ? v : self }
}

// act on the first click even when the window is inactive (it's a floating mini player),
// plus a hover state: soft round highlight that fades in under the pointer, deeper while pressed
final class FirstClickButton: NSButton {
    private var hoverArea: NSTrackingArea?
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseEntered(with e: NSEvent) { highlight(0.12) }
    override func mouseExited(with e: NSEvent) { highlight(0) }
    override func mouseDown(with e: NSEvent) {
        highlight(0.24)
        super.mouseDown(with: e)   // runs the click tracking loop until mouse up
        highlight(bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) ? 0.12 : 0)
    }

    private func highlight(_ alpha: CGFloat) {
        wantsLayer = true
        guard let l = layer else { return }
        l.cornerRadius = min(bounds.width, bounds.height) / 2
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.duration = 0.15
        l.add(a, forKey: "hover")
        l.backgroundColor = alpha > 0 ? NSColor.labelColor.withAlphaComponent(alpha).cgColor : nil
    }
}

// Tiny player surface: click = play/pause, drag = move window (performDrag hands it to the system).
// Buttons inside still get their own clicks.
final class CoverView: NSView {
    var onClick: (() -> Void)?
    private var down: NSEvent?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { let v = super.hitTest(p); return v == nil || v is NSButton ? v : self }
    override func mouseDown(with e: NSEvent) { down = e }
    override func mouseDragged(with e: NSEvent) { if let d = down { down = nil; window?.performDrag(with: d) } }
    override func mouseUp(with e: NSEvent) { if down != nil { onClick?() }; down = nil }
}

struct NowPlaying: Equatable {
    var title = "", artist = "", art = "", playing = false, liked = false, pos = 0.0, dur = 0.0
}

// Polls the page; reports only on change. Title/artist/art from mediaSession (the standard API Spotify fills
// for macOS Now Playing); times + saved state from Spotify's data-testid hooks (verified against the live player).
let bridgeJS = """
const secs = s => (s || "").split(":").map(Number).reduce((a, b) => a * 60 + b, 0);
setInterval(() => {
  const m = navigator.mediaSession.metadata;
  const like = document.querySelector('[data-testid^="now-playing-widget"] button[aria-checked]');
  // mediaSession is empty until playback starts; fall back to the player bar (track loaded but paused)
  const w = document.querySelector('[data-testid^="now-playing-widget"]');
  const cover = w?.querySelector('[data-testid="cover-art-image"]')?.src?.replace(/ab67616d0000(4851|1e02)/, "ab67616d0000b273"); // ponytail: Spotify CDN size codes, 64/300 -> 640px
  const s = { title: m?.title || w?.querySelector('[data-testid="context-item-link"]')?.textContent || "",
              artist: m?.artist || w?.querySelector('[data-testid$="byline"]')?.textContent || "",
              art: m?.artwork?.at(-1)?.src || cover || "",
              playing: navigator.mediaSession.playbackState === "playing" || [...document.querySelectorAll("video,audio")].some(v => !v.paused),
              liked: like?.getAttribute("aria-checked") === "true",
              pos: secs(document.querySelector('[data-testid="playback-position"]')?.textContent),
              dur: secs(document.querySelector('[data-testid="playback-duration"]')?.textContent) };
  const j = JSON.stringify(s);
  if (j !== window.__np) { window.__np = j; webkit.messageHandlers.np.postMessage(s); }
}, 1000);
"""

final class Controller: NSResponder, WKUIDelegate, WKScriptMessageHandler, NSMenuDelegate, NSWindowDelegate, NSApplicationDelegate {
    // standard titled window, transparent titlebar: real traffic lights + system shadow in the rounded shape
    let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    let web: WKWebView
    let glass = NSGlassEffectView()
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let tinySize = NSSize(width: 140, height: 140)
    let miniSize = NSSize(width: 340, height: 500)
    // web player needs ~900px+ or it clips; user's own resize is remembered (also across launches)
    var fullSize = UserDefaults.standard.string(forKey: "fullSize").map(NSSizeFromString) ?? NSSize(width: 980, height: 720)
    var mode = Mode.mini
    var full: Bool { mode == .full }

    // tiny player: cover (click = play/pause) + dislike/like
    let tiny = CoverView()
    let tinyArt = CALayer()
    var tinyLike: NSButton!

    // mini player UI
    let mini = PassThrough()
    let artLayer = CALayer()
    let titleLabel = NSTextField(labelWithString: "Nothing playing")
    let artistLabel = NSTextField(labelWithString: "")
    let posLabel = NSTextField(labelWithString: "")
    let durLabel = NSTextField(labelWithString: "")
    let track = CALayer(), fill = CALayer()
    var playBtn: NSButton!, likeBtn: NSButton!

    var np = NowPlaying()
    // "+" button. Default: the web player's own button (Liked Songs). With the user's own
    // Spotify app connected: the "Liked from ReMini" playlist through the Web API.
    let spotify = SpotifyAPI()
    var saved = false   // in the ReMini playlist (API mode only)
    var trackURI: String?
    var likeBusy = false
    var menuArt: NSImage?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent cookies = stay logged in
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(self, name: "np")   // ponytail: retain cycle, fine for an app-lifetime object

        // Spotify gates on UA; present as Safari
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.pageZoom = UserDefaults.standard.object(forKey: "zoom") as? CGFloat ?? 1
        web.wantsLayer = true
        web.layer?.cornerRadius = 16
        web.layer?.masksToBounds = true

        status.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "ReMini")
        status.button?.imagePosition = .imageLeading
        status.menu = NSMenu()
        status.menu?.delegate = self

        let drag = DragArea()
        drag.menu = {
            let m = NSMenu()
            m.addItem(withTitle: "Reload", action: #selector(WKWebView.reload(_:)), keyEquivalent: "r").target = web
            m.addItem(.separator())
            m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return m
        }()

        glass.cornerRadius = 0   // window clips to its own corner shape; a different radius here shows a double edge
        glass.contentView = drag
        glass.wantsLayer = true

        panel.contentView = glass
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "ReMini"
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false   // close = hide; music keeps playing, Dock/menu bar brings it back
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating   // mini player stays on top of other windows
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setContentSize(miniSize)
        panel.minSize = miniSize; panel.maxSize = miniSize
        // green button = mini <-> full Spotify (our "maximize")
        panel.standardWindowButton(.zoomButton)?.target = self
        panel.standardWindowButton(.zoomButton)?.action = #selector(toggleMode)

        let b = glass.bounds
        drag.frame = b; drag.autoresizingMask = [.width, .height]
        web.frame = NSRect(x: 8, y: 8, width: b.width - 16, height: b.height - 36)
        web.autoresizingMask = [.width, .height]
        // the audio engine in mini mode. alpha 0, NOT isHidden: WebKit suspends hidden views (timers, playback UI)
        web.alphaValue = 0
        drag.addSubview(web)

        buildMini()
        drag.addSubview(mini)
        buildTiny()
        drag.addSubview(tiny)


        if let s = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: s.maxX - miniSize.width - 120, y: s.midY - miniSize.height / 2))
        }
        panel.delegate = self
        panel.orderFrontRegardless()

        // logged out -> Spotify's own login page in full mode (the login form needs the web view)
        cfg.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let loggedIn = cookies.contains { $0.name == "sp_dc" && $0.domain.hasSuffix("spotify.com") }
            let url = loggedIn ? "https://open.spotify.com/"
                               : "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F"
            self.web.load(URLRequest(url: URL(string: url)!))
            if !loggedIn { self.setMode(.full) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Popups (e.g. "Continue with Google") -> open in same view
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        w.load(a.request); return nil
    }

    // MARK: mini player

    func button(_ symbol: String, _ size: CGFloat, _ sel: Selector) -> NSButton {
        let b = FirstClickButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: sel)
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
        b.contentTintColor = .labelColor
        return b
    }

    func buildMini() {
        // fixed 340x500 layout, top-down: bar 28 | art 308 | title | artist | progress | times | controls
        let W = miniSize.width, H = miniSize.height
        func y(_ top: CGFloat, _ h: CGFloat) -> CGFloat { H - top - h }
        mini.frame = NSRect(origin: .zero, size: miniSize)
        mini.wantsLayer = true

        artLayer.frame = NSRect(x: 16, y: y(32, 308), width: 308, height: 308)
        artLayer.cornerRadius = 16
        artLayer.masksToBounds = true
        artLayer.contentsGravity = .resizeAspectFill
        artLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        mini.layer?.addSublayer(artLayer)

        for (l, top, h, font, color) in [(titleLabel, 352.0, 22.0, NSFont.systemFont(ofSize: 17, weight: .bold), NSColor.labelColor),
                                         (artistLabel, 375.0, 18.0, NSFont.systemFont(ofSize: 13, weight: .medium), NSColor.secondaryLabelColor)] {
            l.frame = NSRect(x: 18, y: y(top, h), width: W - 36, height: h)
            l.font = font; l.textColor = color
            l.lineBreakMode = .byTruncatingTail
            mini.addSubview(l)
        }

        track.frame = NSRect(x: 18, y: y(404, 4), width: W - 36, height: 4)
        track.cornerRadius = 2
        track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        fill.frame = NSRect(x: 0, y: 0, width: 0, height: 4)
        fill.cornerRadius = 2
        fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.75).cgColor
        track.addSublayer(fill)
        mini.layer?.addSublayer(track)

        for (l, x, align) in [(posLabel, 18.0, NSTextAlignment.left), (durLabel, W - 18 - 60, .right)] {
            l.frame = NSRect(x: x, y: y(412, 14), width: 60, height: 14)
            l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            l.textColor = .secondaryLabelColor
            l.alignment = align
            mini.addSubview(l)
        }

        let dis = button("hand.thumbsdown", 15, #selector(dislike))
        let prev = button("backward.fill", 18, #selector(prevTrack))
        playBtn = button("play.circle.fill", 40, #selector(playPause))
        let next = button("forward.fill", 18, #selector(nextTrack))
        likeBtn = button("plus.circle", 15, #selector(like))
        dis.toolTip = "Dislike (skip)"
        for (btn, dx) in [(dis, -124.0), (prev, -62.0), (playBtn!, 0.0), (next, 62.0), (likeBtn!, 124.0)] {
            btn.frame = NSRect(x: W / 2 + dx - 24, y: y(436, 48), width: 48, height: 48)
            mini.addSubview(btn)
        }
    }

    func buildTiny() {
        // cover fills the window with a thin glass rim; dislike/like float in its bottom corners
        let m: CGFloat = 6
        tiny.frame = NSRect(origin: .zero, size: tinySize)
        tiny.wantsLayer = true
        tiny.isHidden = true; tiny.alphaValue = 0
        tiny.onClick = { [weak self] in self?.playPause() }
        tiny.toolTip = "Click: play / pause"
        tinyArt.frame = tiny.bounds.insetBy(dx: m, dy: m)
        tinyArt.cornerRadius = 12
        tinyArt.masksToBounds = true
        tinyArt.contentsGravity = .resizeAspectFill
        tinyArt.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        tiny.layer?.addSublayer(tinyArt)

        func chip(_ b: NSButton, x: CGFloat) {
            let g = NSGlassEffectView(frame: NSRect(x: x, y: m + 6, width: 30, height: 30))
            g.cornerRadius = 15
            b.frame = g.bounds
            b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            g.contentView = b
            tiny.addSubview(g)
        }
        let dis = button("hand.thumbsdown", 12, #selector(dislike))
        tinyLike = button("plus.circle", 12, #selector(like))
        dis.toolTip = "Dislike (skip)"
        chip(dis, x: m + 6)
        chip(tinyLike, x: tinySize.width - m - 6 - 30)
    }

    func render() {
        titleLabel.stringValue = np.title.isEmpty ? "Nothing playing" : np.title
        artistLabel.stringValue = np.artist
        posLabel.stringValue = fmt(np.pos)
        durLabel.stringValue = np.dur > 0 ? fmt(np.dur) : ""
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)   // fill glides between 1s polls
        CATransaction.setAnimationTimingFunction(.init(name: .linear))
        fill.frame.size.width = np.dur > 0 ? track.bounds.width * min(np.pos / np.dur, 1) : 0
        CATransaction.commit()

        playBtn.image = NSImage(systemSymbolName: np.playing ? "pause.circle.fill" : "play.circle.fill", accessibilityDescription: nil)
        let api = spotify.isConnected
        let isSaved = api ? saved : np.liked
        let target = api ? SpotifyAPI.playlistName : "Liked Songs"
        let likeImage = NSImage(systemSymbolName: isSaved ? "checkmark.circle.fill" : "plus.circle", accessibilityDescription: nil)
        let likeTip = isSaved ? "In \(target) (click to change)" : "Save to \(target)"
        for b in [likeBtn!, tinyLike!, menuLike] {
            b.image = likeImage
            b.contentTintColor = isSaved ? .systemGreen : .labelColor
            b.toolTip = likeTip
        }
        tinyArt.opacity = np.playing || np.title.isEmpty ? 1 : 0.55   // dimmed cover = paused

        renderMenu()
        statusIcon.image = NSImage(systemSymbolName: np.playing ? "music.note" : "pause.fill", accessibilityDescription: nil)
        setStatusText(np.title.isEmpty ? "" : "\(np.artist) – \(np.title)")
    }

    // Menu bar title. Short text sits as the button title; text wider than maxW scrolls smoothly in a
    // fixed-width clip (a GPU layer animation, so no per-frame redraws and no width jitter).
    let marquee = NSView(), marqueeLayer = CATextLayer()
    let statusIcon = NSImageView()   // drawn by us in marquee mode: an empty-title button would mis-place its image
    var marqueeText = ""

    func setStatusText(_ text: String) {
        guard let b = status.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0), maxW: CGFloat = 220
        let width = { (s: String) in (s as NSString).size(withAttributes: [.font: font]).width }
        if text.isEmpty || width(text) <= maxW {
            marquee.isHidden = true; statusIcon.isHidden = true; marqueeText = ""
            status.length = NSStatusItem.variableLength
            b.image = statusIcon.image
            b.title = text.isEmpty ? "" : " " + text
            return
        }
        b.image = nil
        statusIcon.isHidden = false
        guard text != marqueeText else { return }   // same track: let the running animation continue
        marqueeText = text
        b.title = ""
        status.length = maxW + 30
        if marquee.superview == nil {
            statusIcon.frame = NSRect(x: 4, y: 0, width: 18, height: b.bounds.height)
            statusIcon.contentTintColor = .labelColor
            b.addSubview(statusIcon)
            marquee.wantsLayer = true
            marquee.layer?.masksToBounds = true
            marquee.layer?.addSublayer(marqueeLayer)
            b.addSubview(marquee)
        }
        marquee.isHidden = false
        let gap = "      •      "
        // second copy makes the loop seamless; colour resolved for the menu bar's current appearance
        var color = NSColor.labelColor.cgColor
        b.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        let str = NSAttributedString(string: text + gap + text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
        marqueeLayer.string = str
        marqueeLayer.contentsScale = b.window?.backingScaleFactor ?? 2
        let sz = str.size()
        marquee.frame = NSRect(x: 24, y: 0, width: maxW, height: b.bounds.height)
        marqueeLayer.frame = NSRect(x: 0, y: (b.bounds.height - sz.height) / 2, width: ceil(sz.width), height: ceil(sz.height))
        let shift = width(text + gap)
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = 0; a.toValue = -shift
        a.duration = shift / 30   // 30 pt/s
        a.repeatCount = .infinity
        marqueeLayer.add(a, forKey: "marquee")
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let d = m.body as? [String: Any] else { return }
        let new = NowPlaying(title: d["title"] as? String ?? "", artist: d["artist"] as? String ?? "",
                             art: d["art"] as? String ?? "", playing: d["playing"] as? Bool ?? false,
                             liked: d["liked"] as? Bool ?? false,
                             pos: (d["pos"] as? NSNumber)?.doubleValue ?? 0, dur: (d["dur"] as? NSNumber)?.doubleValue ?? 0)
        if new.art != np.art { loadArt(new.art) }
        let trackChanged = new.title != np.title || new.artist != np.artist
        np = new
        if trackChanged { refreshSaved() }
        render()
    }

    func loadArt(_ s: String) {
        guard let u = URL(string: s) else { artLayer.contents = nil; menuArt = nil; return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let tint = averageColor(cg)
            DispatchQueue.main.async {
                guard let self else { return }
                let t = CATransition(); t.duration = 0.4
                self.artLayer.add(t, forKey: "fade")
                self.artLayer.contents = cg
                self.tinyArt.add(t, forKey: "fade")
                self.tinyArt.contents = cg
                let small = NSImage(cgImage: cg, size: NSSize(width: 44, height: 44))
                self.menuArt = small
                self.renderMenu()
                // glass picks up the album's colour
                NSAnimationContext.runAnimationGroup { _ in self.glass.tintColor = tint?.withAlphaComponent(0.35) }
            }
        }.resume()
    }

    // MARK: menu bar

    // rebuilt every time it opens, so it always reflects the current track
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let card = NSMenuItem(); card.view = menuCard
        let controls = NSMenuItem(); controls.view = menuControls
        menu.addItem(card)
        menu.addItem(controls)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Player", action: #selector(showPanel), keyEquivalent: "").target = self
        for (t, sel, m, key) in [("Tiny Player", #selector(modeTiny), Mode.tiny, "1"), ("Mini Player", #selector(modeMini), .mini, "2"), ("Full Spotify", #selector(modeFull), .full, "3")] {
            let i = menu.addItem(withTitle: t, action: sel, keyEquivalent: key)
            i.target = self
            i.state = mode == m ? .on : .off
        }
        menu.addItem(.separator())
        if spotify.isConnected {
            menu.addItem(withTitle: "Disconnect Spotify API", action: #selector(disconnectSpotify), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Save to \(SpotifyAPI.playlistName) (own Spotify app)…", action: #selector(connectSpotify), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    // Menu bar menu, Control-Center style: cover + title/artist card, then a row of real buttons.
    // Buttons in a menu item view act without closing the menu, so play/like can be toggled in place.
    lazy var menuArtView = NSImageView()
    lazy var menuTitle = NSTextField(labelWithString: "")
    lazy var menuArtist = NSTextField(labelWithString: "")
    lazy var menuPlay = button("play.fill", 18, #selector(playPause))
    lazy var menuLike = button("plus.circle", 15, #selector(like))

    lazy var menuCard: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 68))
        menuArtView.frame = NSRect(x: 14, y: 10, width: 48, height: 48)
        menuArtView.wantsLayer = true
        menuArtView.layer?.cornerRadius = 8
        menuArtView.layer?.masksToBounds = true
        menuArtView.imageScaling = .scaleProportionallyUpOrDown
        for (l, y, f, c) in [(menuTitle, 35.0, NSFont.systemFont(ofSize: 13, weight: .semibold), NSColor.labelColor),
                             (menuArtist, 15.0, NSFont.systemFont(ofSize: 12), NSColor.secondaryLabelColor)] {
            l.frame = NSRect(x: 72, y: y, width: 196, height: 17)
            l.font = f; l.textColor = c
            l.lineBreakMode = .byTruncatingTail
            v.addSubview(l)
        }
        v.addSubview(menuArtView)
        return v
    }()

    lazy var menuControls: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
        let dis = button("hand.thumbsdown", 15, #selector(dislike))
        let prev = button("backward.fill", 16, #selector(prevTrack))
        let next = button("forward.fill", 16, #selector(nextTrack))
        dis.toolTip = "Dislike (skip)"
        for (b, dx) in [(dis, -100.0), (prev, -50.0), (menuPlay, 0.0), (next, 50.0), (menuLike, 100.0)] {
            b.frame = NSRect(x: 140 + dx - 18, y: 4, width: 36, height: 36)
            v.addSubview(b)
        }
        return v
    }()

    func renderMenu() {
        menuTitle.stringValue = np.title.isEmpty ? "Nothing playing" : np.title
        menuArtist.stringValue = np.artist
        menuArtView.image = menuArt ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        menuPlay.image = NSImage(systemSymbolName: np.playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
    }

    // MARK: actions (clicks on the hidden web player)

    func click(_ selector: String) {
        web.evaluateJavaScript("document.querySelector('\(selector)')?.click()")
    }
    @objc func playPause() { click("[data-testid=\"control-button-playpause\"]") }
    @objc func nextTrack() { click("[data-testid=\"control-button-skip-forward\"]") }
    @objc func prevTrack() { click("[data-testid=\"control-button-skip-back\"]") }

    @objc func like() {
        if spotify.isConnected { likeViaAPI() } else { likeInPlayer() }
    }

    // Default, works for everyone: the web player's own "+" button. Not saved: one click saves to
    // Liked Songs. Already saved: Spotify opens its "add to playlist" sheet (that's where you remove
    // it or pick other playlists), so switch to full mode to show it.
    func likeInPlayer() {
        click("[data-testid^=\"now-playing-widget\"] button[aria-checked]")
        if np.liked {
            if !full { setMode(.full) }
            showPanel()
        }
    }

    // Opt-in (own Spotify app connected): toggle the track in the private playlist "Liked from ReMini",
    // created on first use. Uses the Web API, so it does not depend on the player's DOM.
    func likeViaAPI() {
        guard !likeBusy else { return }   // a double click would add and remove again
        likeBusy = true
        Task {
            defer { likeBusy = false }
            do {
                guard let uri = try await spotify.currentTrackURI() else { throw SpotifyError.nothingPlaying }
                trackURI = uri
                saved = try await spotify.toggle(uri)
                render()
            } catch SpotifyError.notLoggedIn {
                render()   // refresh token was revoked: back to the player's button
            } catch {
                showError(error)
            }
        }
    }

    // after a track change: is the new track in the playlist? (only when connected; never prompts)
    func refreshSaved() {
        saved = false
        trackURI = nil
        guard spotify.isConnected, !np.title.isEmpty else { return }
        let title = np.title
        Task {
            try? await Task.sleep(for: .seconds(1.5))   // the API lags the player by a moment
            guard np.title == title, let uri = try? await spotify.currentTrackURI() else { return }
            trackURI = uri
            saved = (try? await spotify.isSaved(uri)) ?? false
            render()
        }
    }

    @objc func connectSpotify() {
        guard spotify.askClientID() else { return }
        Task {
            do { try await spotify.connect(); refreshSaved(); render() }
            catch SpotifyError.cancelled {}
            catch { showError(error) }
        }
    }

    @objc func disconnectSpotify() {
        spotify.disconnect()
        saved = false
        render()
    }

    func showError(_ error: Error) {
        let a = NSAlert(error: error)
        a.messageText = "Could not save the track"
        a.informativeText = error.localizedDescription
        a.runModal()
    }

    // ponytail: Spotify has no real dislike for tracks; skip is the closest universal action
    @objc func dislike() { nextTrack() }

    @objc func showPanel() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func toggleMode() { setMode(full ? .mini : .full) }   // green button
    @objc func modeTiny() { setMode(.tiny) }
    @objc func modeMini() { setMode(.mini) }
    @objc func modeFull() { setMode(.full) }

    // checkmark next to the current size in the View menu
    @objc func validateMenuItem(_ i: NSMenuItem) -> Bool {
        let m: Mode? = [#selector(modeTiny): .tiny, #selector(modeMini): .mini, #selector(modeFull): .full][i.action ?? #selector(NSObject.description)]
        if let m { i.state = mode == m ? .on : .off }
        return true
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        if full {   // leaving full mode: keep whatever size the user dragged it to
            fullSize = panel.frame.size
            UserDefaults.standard.set(NSStringFromSize(fullSize), forKey: "fullSize")
        }
        mode = m
        let size = [Mode.tiny: tinySize, .mini: miniSize, .full: fullSize][m]!
        let v = (panel.screen ?? NSScreen.main!).visibleFrame
        let a = resolveAnchor(anchor, frame: panel.frame, visible: v, newSize: size)
        anchor = a
        let f = placedFrame(panel.frame, size: size, anchor: a, visible: v)

        panel.minSize = full ? NSSize(width: 700, height: 420) : size
        panel.maxSize = full ? NSSize(width: 10000, height: 10000) : size
        mini.isHidden = false; tiny.isHidden = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = m == .tiny   // tiny = just the cover
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = .init(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(f, display: true)
            mini.animator().alphaValue = m == .mini ? 1 : 0
            tiny.animator().alphaValue = m == .tiny ? 1 : 0
            web.animator().alphaValue = m == .full ? 1 : 0
        }, completionHandler: { [self] in
            mini.isHidden = mode != .mini
            tiny.isHidden = mode != .tiny
        })
    }

    // MARK: content zoom (persisted)

    func setZoom(_ z: CGFloat) {
        web.pageZoom = min(max(z, 0.5), 2)
        UserDefaults.standard.set(web.pageZoom, forKey: "zoom")
        if !full { setMode(.full) }   // zoom only means something for the web view
    }
    @objc func zoomIn() { setZoom(web.pageZoom + 0.1) }
    @objc func zoomOut() { setZoom(web.pageZoom - 0.1) }
    @objc func zoomReset() { setZoom(1) }

    // Dock icon click brings the closed window back
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel(); return true
    }

    // MARK: window

    // also save right after a manual resize, so quitting while in full mode keeps it too
    func windowDidEndLiveResize(_ n: Notification) {
        guard full else { return }
        fullSize = panel.frame.size
        UserDefaults.standard.set(NSStringFromSize(fullSize), forKey: "fullSize")
    }

    // corner kept fixed across resizes, see resolveAnchor in Logic.swift
    var anchor: Anchor?
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.applicationIconImage = NSImage(named: "AppIcon")   // Dock caches icons per bundle; set it explicitly so a new icon shows at once
let controller = Controller()
app.delegate = controller

func submenu(_ title: String, _ items: [(String, Selector, String, AnyObject?)]) -> NSMenuItem {
    let m = NSMenu(title: title)
    for (t, sel, key, target) in items {
        if t == "-" { m.addItem(.separator()); continue }
        m.addItem(withTitle: t, action: sel, keyEquivalent: key).target = target
    }
    let i = NSMenuItem(); i.submenu = m; return i
}
let sep = ("-", #selector(NSApplication.terminate(_:)), "", nil as AnyObject?)
let main = NSMenu()
main.addItem(submenu("ReMini", [
    ("Save to Liked from ReMini (own Spotify app)…", #selector(Controller.connectSpotify), "", controller),
    ("Disconnect Spotify API", #selector(Controller.disconnectSpotify), "", controller), sep,
    ("Hide ReMini", #selector(NSApplication.hide(_:)), "h", nil), sep,
    ("Quit ReMini", #selector(NSApplication.terminate(_:)), "q", nil)]))
main.addItem(submenu("Edit", [   // so ⌘C/⌘V/⌘A work in the web view
    ("Cut", #selector(NSText.cut(_:)), "x", nil), ("Copy", #selector(NSText.copy(_:)), "c", nil),
    ("Paste", #selector(NSText.paste(_:)), "v", nil), ("Select All", #selector(NSText.selectAll(_:)), "a", nil)]))
main.addItem(submenu("View", [
    ("Zoom In", #selector(Controller.zoomIn), "=", controller),   // not "+": on e.g. Czech layout that's the 1 key (= Tiny)
    ("Zoom Out", #selector(Controller.zoomOut), "-", controller), ("Actual Size", #selector(Controller.zoomReset), "0", controller), sep,
    ("Tiny Player", #selector(Controller.modeTiny), "1", controller),
    ("Mini Player", #selector(Controller.modeMini), "2", controller),
    ("Full Spotify", #selector(Controller.modeFull), "3", controller),
    ("Reload", #selector(WKWebView.reload(_:)), "r", controller.web)]))
let windowMenu = submenu("Window", [
    ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", nil),
    ("Close", #selector(NSWindow.performClose(_:)), "w", nil)])
main.addItem(windowMenu)
app.mainMenu = main
app.windowsMenu = windowMenu.submenu
app.run()
