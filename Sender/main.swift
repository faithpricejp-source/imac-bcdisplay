// bcd-sender (Mac Studio). Modes:
//   replay --host H a.png b.png    synthetic scroll/typing sequence from screenshots (M1 test)
//   live   --host H                virtual display + ScreenCaptureKit (M2)
import Foundation
import Metal
import CoreGraphics
import ImageIO

let argv = CommandLine.arguments
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
let mode = argv.count > 1 ? argv[1] : "help"
let host = opt("--host") ?? ""   // replay needs it; live uses Bonjour (wired only) unless --host is given
let port = UInt16(opt("--port") ?? "") ?? BCD.port
let exeDir = URL(fileURLWithPath: argv[0]).deletingLastPathComponent().path
let kernelPath = opt("--kernels") ?? Bundle.main.path(forResource: "BCKernels", ofType: "metal") ?? "\(exeDir)/BCKernels.metal"
let kernelSrc = try! String(contentsOfFile: kernelPath, encoding: .utf8)
let dev = MTLCreateSystemDefaultDevice()!

func loadRGBA(_ path: String) -> (Int, Int, [UInt8]) {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

func runReplay() {
    guard !host.isEmpty else { print("replay needs --host <receiver IP>"); exit(1) }
    let a = loadRGBA(argv[argv.count - 2]), b = loadRGBA(argv[argv.count - 1])
    let w = a.0, h = a.1
    let enc = BC7Encoder(dev: dev, kernelSource: kernelSrc, width: w, height: h)
    let fs = FrameSender(enc: enc)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    td.usage = [.shaderRead]
    let tex = dev.makeTexture(descriptor: td)!
    // tall page = A then B; scrolling shows a 2880-row window of it
    let page = a.2 + b.2
    let rowBytes = w * 4
    func show(scrollRows: Int, typingToggle: Bool) {
        let start = (scrollRows % (2 * h))
        var frame = [UInt8](repeating: 0, count: w * h * 4)
        frame.withUnsafeMutableBytes { f in page.withUnsafeBytes { p in
            for y in 0..<h {
                let sy = (start + y) % (2 * h)
                memcpy(f.baseAddress! + y * rowBytes, p.baseAddress! + sy * rowBytes, rowBytes)
            }
        }}
        if typingToggle { for y in 1000..<1040 { for x in 800..<1400 { let i = (y * w + x) * 4; frame[i] = 255 &- frame[i] } } }
        fs.q.async {
            frame.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: rowBytes) }
            let ts = nowNs()
            enc.encode(tex); fs.frameEncoded(captureTs: ts)
        }
    }
    let sema = DispatchSemaphore(value: 0)
    connect(host: host, port: port, queue: fs.q, onReady: { c in fs.attach(c); sema.signal() }, onClose: { slog("closed: \($0)"); exit(2) })
    guard sema.wait(timeout: .now() + 10) == .success else { slog("connect timeout"); exit(2) }
    slog("connected to \(host):\(port)")
    let stats = Timer(timeInterval: 1, repeats: true) { _ in fs.logStats(); fs.ping() }
    RunLoop.main.add(stats, forMode: .common)
    for _ in 0..<5 { fs.ping(); usleep(20_000) }

    DispatchQueue.global().async {
        func dumpCheck(_ label: String) {
            let s = DispatchSemaphore(value: 0)
            fs.requestDump { r, l in slog("DUMP \(label): receiver=\(String(r, radix: 16)) local=\(String(l, radix: 16)) \(r == l ? "MATCH" : "MISMATCH")"); s.signal() }
            _ = s.wait(timeout: .now() + 10)
        }
        slog("phase: full frame"); show(scrollRows: 0, typingToggle: false); sleep(2); dumpCheck("full")
        slog("phase: scroll 24px/frame @60Hz for 4s")
        for k in 0..<240 { show(scrollRows: k * 24, typingToggle: false); usleep(16_667) }
        sleep(2)
        slog("phase: typing toggle @10Hz for 3s")
        for k in 0..<30 { show(scrollRows: 239 * 24, typingToggle: k % 2 == 0); usleep(100_000) }
        sleep(2); dumpCheck("end")
        slog("done"); exit(0)
    }
    RunLoop.main.run()
}

switch mode {
case "replay": runReplay()
case "live": runLive()
default:
    print("usage: bcd-sender replay --host H a.png b.png | live --host H"); exit(1)
}
