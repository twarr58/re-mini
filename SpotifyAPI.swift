import AppKit
import Security
import WebKit

// Spotify Web API client for the "+" button: saves the current track to a private playlist
// ("Liked from ReMini"). Auth is Authorization Code + PKCE, so no client secret is stored;
// the user registers their own app and enters its Client ID once.

enum SpotifyError: LocalizedError {
    case noClientID, cancelled, denied(String), stateMismatch, notLoggedIn, nothingPlaying
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noClientID: return "No Spotify Client ID is set."
        case .cancelled: return "Connecting to Spotify was cancelled."
        case .denied(let e): return "Spotify refused access (\(e))."
        case .stateMismatch: return "The Spotify login response did not match the request."
        case .notLoggedIn: return "ReMini is not connected to the Spotify API."
        case .nothingPlaying: return "Spotify does not report a track playing right now."
        case .http(let code, let body): return "Spotify API error \(code): \(body.prefix(300))"
        }
    }
}

@MainActor
final class SpotifyAPI {
    static let redirectURI = "http://127.0.0.1:43821/callback"
    static let playlistName = "Liked from ReMini"
    static let scopes = ["user-read-currently-playing", "playlist-read-private",
                         "playlist-modify-private", "playlist-modify-public"]

    private let defaults = UserDefaults.standard
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var playlistURIs: Set<String>?   // tracks in the playlist, loaded once per session

    var clientID: String? {
        get { defaults.string(forKey: "spotifyClientID").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "spotifyClientID") }
    }
    private var playlistID: String? {
        get { defaults.string(forKey: "spotifyPlaylistID") }
        set { defaults.set(newValue, forKey: "spotifyPlaylistID") }
    }
    var isConnected: Bool { clientID != nil && Keychain.refreshToken != nil }

    func disconnect() {
        Keychain.refreshToken = nil
        accessToken = nil
        playlistURIs = nil
    }

    // MARK: login

    private var authWindow: AuthWindow?

    /// Opens Spotify's consent page in a small window. The web view shares the player's cookies,
    /// so the user is usually logged in already and only has to click "Agree".
    func connect() async throws {
        guard let clientID else { throw SpotifyError.noClientID }
        let verifier = pkceVerifier(), state = UUID().uuidString
        let url = spotifyAuthorizeURL(clientID: clientID, redirectURI: Self.redirectURI, scopes: Self.scopes,
                                      state: state, challenge: pkceChallenge(for: verifier))
        let result: AuthCallback = try await withCheckedThrowingContinuation { cont in
            let w = AuthWindow(url: url) { callbackURL in
                guard let callbackURL else { return cont.resume(throwing: SpotifyError.cancelled) }
                cont.resume(returning: parseAuthCallback(callbackURL, redirectURI: Self.redirectURI, state: state) ?? .stateMismatch)
            }
            authWindow = w
            w.show()
        }
        authWindow = nil
        switch result {
        case .code(let code):
            try await token([("grant_type", "authorization_code"), ("code", code),
                             ("redirect_uri", Self.redirectURI), ("client_id", clientID), ("code_verifier", verifier)])
        case .denied(let e): throw SpotifyError.denied(e)
        case .stateMismatch: throw SpotifyError.stateMismatch
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }

    private func token(_ fields: [(String, String)]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(formEncode(fields).utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // a revoked or expired refresh token: forget it, the next click starts a new login
            if status == 400 || status == 401 { disconnect() }
            throw SpotifyError.http(status, String(decoding: data, as: UTF8.self))
        }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = t.access_token
        accessExpiry = Date().addingTimeInterval(t.expires_in - 60)
        if let r = t.refresh_token { Keychain.refreshToken = r }   // Spotify may rotate it
    }

    private func validToken() async throws -> String {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let clientID, let refresh = Keychain.refreshToken else { throw SpotifyError.notLoggedIn }
        try await token([("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", clientID)])
        return accessToken!
    }

    // MARK: requests

    private func call(_ method: String, _ path: String, json: Any? = nil, retry: Bool = true) async throws -> (Data, Int) {
        let url = path.hasPrefix("https://") ? URL(string: path)! : URL(string: "https://api.spotify.com/v1" + path)!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {   // token revoked or expired early
            accessToken = nil
            return try await call(method, path, json: json, retry: false)
        }
        return (data, status)
    }

    private func ok(_ r: (Data, Int)) throws -> Data {
        guard (200..<300).contains(r.1) else { throw SpotifyError.http(r.1, String(decoding: r.0, as: UTF8.self)) }
        return r.0
    }

    // Spotify has been renaming playlist endpoints (`/tracks` -> `/items`, `/users/{id}/playlists` -> `/me/playlists`).
    // Try the newer path first and fall back when it does not exist.
    private func callEither(_ method: String, _ paths: [String], json: Any? = nil) async throws -> Data {
        var last: (Data, Int) = (Data(), 0)
        for p in paths {
            last = try await call(method, p, json: json)
            if last.1 != 404 && last.1 != 410 { break }
        }
        return try ok(last)
    }

    private struct Item: Decodable { let uri: String? }
    private struct NowPlayingResponse: Decodable { let item: Item? }

    /// Spotify URI of the track playing on any device (the web player included), or nil.
    func currentTrackURI() async throws -> String? {
        let r = try await call("GET", "/me/player/currently-playing")
        if r.1 == 204 { return nil }
        let uri = try JSONDecoder().decode(NowPlayingResponse.self, from: ok(r)).item?.uri
        return uri?.hasPrefix("spotify:track:") == true ? uri : nil
    }

    private struct Me: Decodable { let id: String }
    private struct Owner: Decodable { let id: String }
    private struct Playlist: Decodable { let id: String; let name: String; let owner: Owner }
    private struct Page<T: Decodable>: Decodable { let items: [T?]; let next: String? }   // entries can be null
    private struct PlaylistEntry: Decodable { let track: Item?; let item: Item? }

    private func ensurePlaylist() async throws -> String {
        if let playlistID { return playlistID }
        let me = try JSONDecoder().decode(Me.self, from: ok(try await call("GET", "/me")))
        var next: String? = "/me/playlists?limit=50"
        while let path = next {
            let page = try JSONDecoder().decode(Page<Playlist>.self, from: ok(try await call("GET", path)))
            if let p = page.items.compactMap({ $0 }).first(where: { $0.name == Self.playlistName && $0.owner.id == me.id }) {
                playlistID = p.id
                return p.id
            }
            next = page.next
        }
        let body: [String: Any] = ["name": Self.playlistName, "public": false,
                                   "description": "Tracks saved with the + button in ReMini."]
        let created = try JSONDecoder().decode(Playlist.self,
                                               from: try await callEither("POST", ["/me/playlists", "/users/\(me.id)/playlists"], json: body))
        playlistID = created.id
        playlistURIs = []
        return created.id
    }

    private func loadPlaylist(_ id: String) async throws -> Set<String> {
        if let playlistURIs { return playlistURIs }
        var uris = Set<String>()
        var paths = ["/playlists/\(id)/items?limit=100", "/playlists/\(id)/tracks?limit=100"]
        while !paths.isEmpty {
            let page = try JSONDecoder().decode(Page<PlaylistEntry>.self, from: try await callEither("GET", paths))
            for e in page.items.compactMap({ $0 }) { if let u = (e.item ?? e.track)?.uri { uris.insert(u) } }
            paths = page.next.map { [$0] } ?? []
        }
        playlistURIs = uris
        return uris
    }

    /// Is the track in the ReMini playlist? Loads the playlist once, then answers from memory.
    func isSaved(_ uri: String) async throws -> Bool {
        do {
            return try await loadPlaylist(try await ensurePlaylist()).contains(uri)
        } catch SpotifyError.http(404, _) {   // playlist deleted in Spotify: forget it and start again
            playlistID = nil; playlistURIs = nil
            return try await loadPlaylist(try await ensurePlaylist()).contains(uri)
        }
    }

    /// Adds the track to the playlist, or removes it when it is already there. Returns the new state.
    func toggle(_ uri: String) async throws -> Bool {
        let saved = try await isSaved(uri)
        let id = try await ensurePlaylist()
        if saved {
            _ = try await callEither("DELETE", ["/playlists/\(id)/items", "/playlists/\(id)/tracks"],
                                     json: ["items": [["uri": uri]], "tracks": [["uri": uri]]])
            playlistURIs?.remove(uri)
        } else {
            _ = try await callEither("POST", ["/playlists/\(id)/items", "/playlists/\(id)/tracks"], json: ["uris": [uri]])
            playlistURIs?.insert(uri)
        }
        return !saved
    }

    // MARK: setup dialog

    /// Asks for the Client ID of the user's own Spotify app. Returns false when cancelled.
    func askClientID() -> Bool {
        let a = NSAlert()
        a.messageText = "Connect ReMini to Spotify"
        a.informativeText = """
        The + button saves tracks to your playlist "\(Self.playlistName)" through the Spotify Web API. \
        For that you need your own (free) Spotify app:

        1. Open developer.spotify.com/dashboard and create an app.
        2. Add this Redirect URI: \(Self.redirectURI)
        3. Tick "Web API" and save.
        4. Paste the app's Client ID below.
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Client ID"
        field.stringValue = clientID ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Copy Redirect URI")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        while true {
            switch a.runModal() {
            case .alertFirstButtonReturn:
                let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }
                if id != clientID { disconnect(); playlistID = nil }
                clientID = id
                return true
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.redirectURI, forType: .string)
            default:
                return false
            }
        }
    }
}

// MARK: consent window

/// Shows the authorize page and reports the redirect URL (or nil if the user closes the window).
/// The redirect itself is never loaded: nothing listens on 127.0.0.1.
@MainActor
final class AuthWindow: NSObject, WKNavigationDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let web: WKWebView
    private var done: ((URL?) -> Void)?

    init(url: URL, done: @escaping (URL?) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // same cookies as the player: already logged in
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.done = done
        super.init()
        window.title = "Connect to Spotify"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.level = .floating   // above the floating player
        window.delegate = self
        web.navigationDelegate = self
        web.load(URLRequest(url: url))
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func finish(_ url: URL?) {
        guard let done else { return }
        self.done = nil
        done(url)
        window.close()
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let u = a.request.url, u.absoluteString.hasPrefix(SpotifyAPI.redirectURI) else { return .allow }
        finish(u)
        return .cancel
    }

    func windowWillClose(_ n: Notification) { finish(nil) }
}

// MARK: keychain

enum Keychain {
    private static let service = "local.remini.spotify"
    private static let account = "refresh_token"

    static var refreshToken: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
            SecItemDelete(q as CFDictionary)
            guard let newValue else { return }
            var add = q
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
