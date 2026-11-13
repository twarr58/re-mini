import AppKit

// Minimal dependency-free test runner (XCTest/Swift Testing need full Xcode).
// Built together with ../Logic.swift by `make test`.

var failures = 0
var checks = 0

func expect(_ ok: @autoclosure () -> Bool, _ message: @autoclosure () -> String,
            file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !ok() {
        failures += 1
        print("  ✗ \(file):\(line): \(message())")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) {
    expect(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
}

func expectClose(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.05,
                 file: StaticString = #fileID, line: UInt = #line) {
    expect(abs(actual - expected) <= tolerance, "expected \(expected) ± \(tolerance), got \(actual)", file: file, line: line)
}

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

// MARK: fmt

test("fmt formats m:ss") {
    expectEqual(fmt(0), "0:00")
    expectEqual(fmt(5), "0:05")
    expectEqual(fmt(59.9), "0:59")
    expectEqual(fmt(60), "1:00")
    expectEqual(fmt(754), "12:34")
    expectEqual(fmt(3600), "60:00")
}

test("fmt survives bad input") {
    expectEqual(fmt(-3), "0:00")
    expectEqual(fmt(.nan), "0:00")
    expectEqual(fmt(.infinity), "0:00")
}

// MARK: window anchoring

let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
let mini = NSSize(width: 340, height: 500)
let full = NSSize(width: 500, height: 520)

test("anchor follows the nearer screen edges when growing") {
    let bottomLeft = NSRect(x: 50, y: 50, width: 340, height: 500)
    expectEqual(resolveAnchor(nil, frame: bottomLeft, visible: screen, newSize: full), Anchor(left: true, bottom: true))
    let topRight = NSRect(x: 600, y: 250, width: 340, height: 500)
    expectEqual(resolveAnchor(nil, frame: topRight, visible: screen, newSize: full), Anchor(left: false, bottom: false))
}

test("growing recomputes the anchor, shrinking keeps it") {
    let stale = Anchor(left: false, bottom: false)
    let bottomLeft = NSRect(x: 50, y: 50, width: 340, height: 500)
    expectEqual(resolveAnchor(stale, frame: bottomLeft, visible: screen, newSize: full), Anchor(left: true, bottom: true))
    let big = NSRect(x: 400, y: 200, width: 500, height: 520)   // centre is in the top-right quadrant
    let kept = Anchor(left: true, bottom: true)
    expectEqual(resolveAnchor(kept, frame: big, visible: screen, newSize: mini), kept)
}

test("placedFrame keeps the anchored corner") {
    let f = NSRect(x: 600, y: 250, width: 340, height: 500)
    let r = placedFrame(f, size: full, anchor: Anchor(left: false, bottom: false), visible: screen)
    expectEqual(r, NSRect(x: 440, y: 230, width: 500, height: 520))   // right and top edges unchanged
    expectEqual(r.maxX, f.maxX)
    expectEqual(r.maxY, f.maxY)
}

test("placedFrame stays on screen") {
    let f = NSRect(x: 400, y: 600, width: 140, height: 140)
    let r = placedFrame(f, size: NSSize(width: 900, height: 700), anchor: Anchor(left: true, bottom: true), visible: screen)
    expect(screen.contains(r), "\(r) is not inside \(screen)")
    expectEqual(r.origin, NSPoint(x: 100, y: 100))
}

test("mini -> full -> mini returns to the same frame") {
    for start in [NSRect(x: 50, y: 50, width: 340, height: 500),
                  NSRect(x: 600, y: 250, width: 340, height: 500),
                  NSRect(x: 40, y: 280, width: 340, height: 500),
                  NSRect(x: 620, y: 20, width: 340, height: 500)] {
        var anchor: Anchor? = nil
        anchor = resolveAnchor(anchor, frame: start, visible: screen, newSize: full)
        let grown = placedFrame(start, size: full, anchor: anchor!, visible: screen)
        anchor = resolveAnchor(anchor, frame: grown, visible: screen, newSize: mini)
        let back = placedFrame(grown, size: mini, anchor: anchor!, visible: screen)
        expect(back == start, "round trip from \(start) ended at \(back)")
    }
}

// MARK: averageColor

func image(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

test("averageColor of a solid image is that colour") {
    let red = image(width: 8, height: 8) { $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
    guard let c = averageColor(red) else { return expect(false, "nil colour") }
    expectClose(c.redComponent, 1)
    expectClose(c.greenComponent, 0)
    expectClose(c.blueComponent, 0)
}

test("averageColor mixes colours") {
    let half = image(width: 2, height: 2) {
        $0.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
        $0.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); $0.fill(CGRect(x: 1, y: 0, width: 1, height: 2))
    }
    guard let c = averageColor(half) else { return expect(false, "nil colour") }
    expectClose(c.redComponent, 0.5, tolerance: 0.2)
    expectClose(c.greenComponent, 0, tolerance: 0.05)
    expectClose(c.blueComponent, 0.5, tolerance: 0.2)
}

print("\n\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
