import AppKit

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
