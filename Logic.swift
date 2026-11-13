import AppKit
import CryptoKit

// Pure helpers without UI state. Compiled into the app and into the unit tests (Tests/main.swift).

/// Seconds as `m:ss`. Non-finite or negative input shows `0:00` instead of crashing in `Int(_:)`.
func fmt(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "0:00" }
    let t = Int(s)
    return String(format: "%d:%02d", t / 60, t % 60)
}

/// Which corner of the window stays put when it is resized.
struct Anchor: Equatable {
    var left: Bool
    var bottom: Bool
}

// Grow away from the nearer screen edges: a window in the left half keeps its left edge (grows right),
// one in the right half keeps its right edge (grows left); same for top/bottom.
// The corner is decided when growing (from the small window) and reused when shrinking back,
// otherwise the big window's centre would pick a different corner and the round trip would drift.
func resolveAnchor(_ current: Anchor?, frame f: NSRect, visible v: NSRect, newSize size: NSSize) -> Anchor {
    if let current, size.width * size.height <= f.width * f.height { return current }
    return Anchor(left: f.midX < v.midX, bottom: f.midY < v.midY)
}

/// The new window frame for `size`, keeping the anchored corner of `f` and staying inside `v`.
func placedFrame(_ f: NSRect, size: NSSize, anchor a: Anchor, visible v: NSRect) -> NSRect {
    var r = NSRect(x: a.left ? f.minX : f.maxX - size.width,
                   y: a.bottom ? f.minY : f.maxY - size.height,
                   width: size.width, height: size.height)
    r.origin.x = min(max(r.origin.x, v.minX), v.maxX - size.width)
    r.origin.y = min(max(r.origin.y, v.minY), v.maxY - size.height)
    return r
}

/// Average colour of an image (1x1 downsample), used to tint the glass.
func averageColor(_ cg: CGImage) -> NSColor? {
    var px = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
}

// MARK: Spotify OAuth (Authorization Code with PKCE, no client secret)

/// Base64url without padding (RFC 4648 §5), as PKCE and JWT use it.
func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Random PKCE code verifier: 64 random bytes -> 86 characters (allowed: 43...128).
func pkceVerifier() -> String {
    var rng = SystemRandomNumberGenerator()
    return base64URL(Data((0..<64).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
}

/// S256 code challenge for a verifier.
func pkceChallenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
}

/// application/x-www-form-urlencoded body; keeps the field order.
func formEncode(_ fields: [(String, String)]) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
    return fields.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
}

func spotifyAuthorizeURL(clientID: String, redirectURI: String, scopes: [String], state: String, challenge: String) -> URL {
    var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
    c.queryItems = [
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
    ]
    return c.url!
}

enum AuthCallback: Equatable {
    case code(String)
    case denied(String)
    case stateMismatch
}

/// Result of the OAuth redirect, or nil when `url` is not the redirect URI (keep navigating).
func parseAuthCallback(_ url: URL, redirectURI: String, state: String) -> AuthCallback? {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let r = URLComponents(string: redirectURI),
          c.scheme == r.scheme, c.host == r.host, c.port == r.port, c.path == r.path else { return nil }
    var q: [String: String] = [:]
    for item in c.queryItems ?? [] where q[item.name] == nil { q[item.name] = item.value ?? "" }
    guard q["state"] == state else { return .stateMismatch }
    if let code = q["code"], !code.isEmpty { return .code(code) }
    return .denied(q["error"] ?? "unknown_error")
}

// MARK: player memory

/// The web player (open.spotify.com) grows to several GB over a long session. Reload it when its process
/// passes `limit`, but never while the user is looking at it (Full mode) and never in the middle of a track:
/// when paused right away, while playing only at a track change (then playback resumes on the next track).
func shouldReloadPlayer(footprint: UInt64?, limit: UInt64, playing: Bool, fullMode: Bool,
                        trackJustChanged: Bool, sinceLastReload: TimeInterval) -> Bool {
    guard let footprint, footprint >= limit, !fullMode, sinceLastReload >= 600 else { return false }
    return !playing || trackJustChanged
}
