// Draws the 1024px app icon: an iMac whose screen is a mosaic of BC7-style tiles, fed by a stream of packets.
// usage: make_icon <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])! }
func rrect(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

// --- squircle background (macOS icon grid: 824pt body inset 100) ---
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
ctx.addPath(rrect(body, 186)); ctx.setFillColor(c(20, 30, 70)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rrect(body, 186)); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [c(14, 112, 132), c(36, 52, 128), c(26, 22, 70)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 260, y: 100), end: CGPoint(x: 760, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// soft top sheen
let sheen = CGGradient(colorsSpace: cs, colors: [c(255, 255, 255, 0.16), c(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// --- monitor ---
let screenOuter = CGRect(x: 232, y: 392, width: 560, height: 352)
// stand
ctx.setFillColor(c(206, 214, 228))
let stand = CGMutablePath()
stand.move(to: CGPoint(x: 462, y: 392)); stand.addLine(to: CGPoint(x: 562, y: 392))
stand.addLine(to: CGPoint(x: 590, y: 300)); stand.addLine(to: CGPoint(x: 434, y: 300)); stand.closeSubpath()
ctx.addPath(stand); ctx.fillPath()
ctx.addPath(rrect(CGRect(x: 400, y: 284, width: 224, height: 24), 12)); ctx.setFillColor(c(232, 237, 245)); ctx.fillPath()
// chin + bezel
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0, 0, 0, 0.4))
ctx.addPath(rrect(CGRect(x: screenOuter.minX, y: screenOuter.minY - 56, width: screenOuter.width, height: screenOuter.height + 56), 34))
ctx.setFillColor(c(240, 244, 250)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(rrect(CGRect(x: screenOuter.minX, y: screenOuter.minY - 56, width: screenOuter.width, height: 70), 34))
ctx.setFillColor(c(214, 222, 236)); ctx.fillPath()
// glass
let glass = screenOuter.insetBy(dx: 18, dy: 18)
ctx.addPath(rrect(glass, 14)); ctx.setFillColor(c(12, 18, 44)); ctx.fillPath()

// --- tile mosaic on the glass (8 x 5 tiles), a few "fresh" tiles lit up ---
ctx.saveGState()
ctx.addPath(rrect(glass, 14)); ctx.clip()
let cols = 8, rows = 5
let gap: CGFloat = 6
let tw = (glass.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
let th = (glass.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
let fresh: Set<Int> = [2, 3, 11, 12, 13, 20, 29]
for r in 0..<rows {
    for col in 0..<cols {
        let i = r * cols + col
        let x = glass.minX + gap + CGFloat(col) * (tw + gap)
        let y = glass.maxY - gap - th - CGFloat(r) * (th + gap)
        let t = CGFloat(col) / CGFloat(cols - 1)
        let base = fresh.contains(i)
            ? c(120 + 100 * t, 230, 255)
            : c(40 + 30 * t, 70 + 60 * (1 - t), 140 + 40 * t, 0.85)
        ctx.addPath(rrect(CGRect(x: x, y: y, width: tw, height: th), 7)); ctx.setFillColor(base); ctx.fillPath()
        if fresh.contains(i) {   // 4x4 block grid hint inside lit tiles
            ctx.setStrokeColor(c(255, 255, 255, 0.35)); ctx.setLineWidth(1.5)
            for k in 1..<4 {
                ctx.move(to: CGPoint(x: x + tw * CGFloat(k) / 4, y: y + 4)); ctx.addLine(to: CGPoint(x: x + tw * CGFloat(k) / 4, y: y + th - 4))
                ctx.move(to: CGPoint(x: x + 4, y: y + th * CGFloat(k) / 4)); ctx.addLine(to: CGPoint(x: x + tw - 4, y: y + th * CGFloat(k) / 4))
            }
            ctx.strokePath()
        }
    }
}
// glass reflection
let refl = CGMutablePath()
refl.move(to: CGPoint(x: glass.minX, y: glass.maxY)); refl.addLine(to: CGPoint(x: glass.minX + 230, y: glass.maxY))
refl.addLine(to: CGPoint(x: glass.minX + 80, y: glass.minY)); refl.addLine(to: CGPoint(x: glass.minX, y: glass.minY)); refl.closeSubpath()
ctx.addPath(refl); ctx.setFillColor(c(255, 255, 255, 0.06)); ctx.fillPath()
ctx.restoreGState()

// --- incoming packet stream (from the left, into the screen) ---
let packets: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(128, 557, 22, 0.35), (162, 553, 30, 0.6), (200, 549, 38, 0.95)]
for (x, y, s, a) in packets {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: c(120, 240, 255, a))
    ctx.addPath(rrect(CGRect(x: x, y: y, width: s, height: s), s * 0.22)); ctx.setFillColor(c(150, 240, 255, a)); ctx.fillPath()
    ctx.restoreGState()
}

let img = ctx.makeImage()!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dst, img, nil)
CGImageDestinationFinalize(dst)
print("wrote \(CommandLine.arguments[1])")
