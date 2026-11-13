// Renders AppIcon.icns with a hand-written "RE" on top.
//   swift make-icon.swift              -> own design (green disc + waveform)
//   swift make-icon.swift base.png     -> your own base image (e.g. an icon you have the rights to use)
import AppKit

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: px, height: px)

if CommandLine.arguments.count > 1, let base = NSImage(contentsOfFile: CommandLine.arguments[1]) {
    base.draw(in: canvas)
} else {
    // macOS icon grid: 824pt body, 100pt margin
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -12)
    sh.shadowColor = .black.withAlphaComponent(0.35); sh.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.05, alpha: 1)])!.draw(in: shape, angle: -90)

    // green disc, slightly low so the lettering sits above it
    let disc = NSBezierPath(ovalIn: NSRect(x: 252, y: 170, width: 520, height: 520))
    NSGradient(colors: [NSColor(red: 0.16, green: 0.88, blue: 0.45, alpha: 1),
                        NSColor(red: 0.07, green: 0.62, blue: 0.30, alpha: 1)])!.draw(in: disc, angle: -90)

    // waveform bars
    NSColor(white: 0.06, alpha: 1).setFill()
    for (i, h) in [120.0, 220, 300, 220, 120].enumerated() {
        let x = 512 - 2 * 70 + Double(i) * 70 - 22
        NSBezierPath(roundedRect: NSRect(x: x, y: 430 - h / 2, width: 44, height: h), xRadius: 22, yRadius: 22).fill()
    }

    // glass sheen
    shape.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.18), .white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
}

// hand-written "RE", tilted, on top
let font = NSFont(name: "BradleyHandITCTT-Bold", size: 330) ?? NSFont(name: "MarkerFelt-Wide", size: 300)!
let ink = NSShadow(); ink.shadowBlurRadius = 18; ink.shadowOffset = NSSize(width: 0, height: -6)
ink.shadowColor = .black.withAlphaComponent(0.6)
let text = NSAttributedString(string: "RE", attributes: [
    .font: font, .foregroundColor: NSColor.white, .shadow: ink,
])
let ctx = NSGraphicsContext.current!.cgContext
ctx.resetClip()
ctx.saveGState()
ctx.translateBy(x: 512, y: 735)
ctx.rotate(by: 8 * .pi / 180)
let sz = text.size()
text.draw(at: NSPoint(x: -sz.width / 2, y: -sz.height / 2))
ctx.restoreGState()

NSGraphicsContext.current = nil

let dir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/icon_512x512@2x.png"))
func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = nil
    try! p.run(); p.waitUntilExit()
}
for s in [16, 32, 128, 256, 512] {
    for scale in [1, 2] where !(s == 512 && scale == 2) {
        let name = scale == 1 ? "icon_\(s)x\(s).png" : "icon_\(s)x\(s)@2x.png"
        run("/usr/bin/sips", ["-z", "\(s * scale)", "\(s * scale)", "\(dir)/icon_512x512@2x.png", "--out", "\(dir)/\(name)"])
    }
}
run("/usr/bin/iconutil", ["-c", "icns", dir, "-o", "AppIcon.icns"])
try? FileManager.default.removeItem(atPath: dir)
print("wrote AppIcon.icns")
