// Phase 0 bench: BC7-mode6 / BC1 GPU encode on real 5K screenshots, tile diff, LZ4/LZFSE sizes, quality.
// usage: p0bench <kernels.metal.txt> <outdir> <a.png> <b.png>
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Compression

let args = CommandLine.arguments
let kernelPath = args[1], outDir = args[2], pathA = args[3], pathB = args[4]
let dev = MTLCreateSystemDefaultDevice()!
let lib = try! dev.makeLibrary(source: String(contentsOfFile: kernelPath, encoding: .utf8), options: nil)
let q = dev.makeCommandQueue()!
func pso(_ n: String) -> MTLComputePipelineState { try! dev.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
let psoBC7 = pso("bc7_mode6"), psoBC1 = pso("bc1"), psoRB = pso("readback")

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
func savePNG(_ path: String, _ w: Int, _ h: Int, _ px: [UInt8]) {
    var p = px
    let ctx = CGContext(data: &p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
func texFrom(_ w: Int, _ h: Int, _ px: [UInt8]) -> MTLTexture {
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    td.usage = [.shaderRead]
    let t = dev.makeTexture(descriptor: td)!
    px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
    return t
}

struct Enc { let data: Data; let gpuMs: Double }
func encode(_ t: MTLTexture, bc7: Bool) -> Enc {
    let bw = (t.width + 3) / 4, bh = (t.height + 3) / 4
    let bpb = bc7 ? 16 : 8
    let out = dev.makeBuffer(length: bw * bh * bpb, options: .storageModeShared)!
    var bwU = UInt32(bw)
    var best = 1e9
    for _ in 0..<5 {   // warm up + take best
        let cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(bc7 ? psoBC7 : psoBC1)
        e.setTexture(t, index: 0); e.setBuffer(out, offset: 0, index: 0); e.setBytes(&bwU, length: 4, index: 1)
        e.dispatchThreads(MTLSize(width: bw, height: bh, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }
    return Enc(data: Data(bytes: out.contents(), count: out.length), gpuMs: best)
}
func decode(_ enc: Data, w: Int, h: Int, bc7: Bool) -> [UInt8] {
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: bc7 ? .bc7_rgbaUnorm : .bc1_rgba, width: w, height: h, mipmapped: false)
    td.usage = [.shaderRead]
    let t = dev.makeTexture(descriptor: td)!
    let bw = (w + 3) / 4
    enc.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bw * (bc7 ? 16 : 8)) }
    let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    od.usage = [.shaderWrite]; od.storageMode = .shared
    let o = dev.makeTexture(descriptor: od)!
    let cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(psoRB); e.setTexture(t, index: 0); e.setTexture(o, index: 1)
    e.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: w * h * 4)
    px.withUnsafeMutableBytes { o.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
    return px
}
func psnr(_ a: [UInt8], _ b: [UInt8]) -> (Double, Int) {
    var se = 0.0, maxd = 0
    for i in 0..<a.count where i % 4 != 3 { let d = Int(a[i]) - Int(b[i]); se += Double(d * d); maxd = max(maxd, abs(d)) }
    let mse = se / Double(a.count / 4 * 3)
    return (10 * log10(255 * 255 / max(mse, 1e-9)), maxd)
}
// tiles of 64x64 px = 16x16 blocks
func tileSet(_ a: Data?, _ b: Data, w: Int, h: Int, bpb: Int) -> (Data, Int, Int) {
    let bw = (w + 3) / 4, bh = (h + 3) / 4, T = 16
    let tw = (bw + T - 1) / T, th = (bh + T - 1) / T
    var payload = Data(); var dirty = 0
    b.withUnsafeBytes { bp in
        let bb = bp.bindMemory(to: UInt8.self)
        for ty in 0..<th { for tx in 0..<tw {
            var changed = (a == nil)
            var rows: [Range<Int>] = []
            for by in (ty * T)..<min((ty + 1) * T, bh) {
                let s = (by * bw + tx * T) * bpb, e = (by * bw + min((tx + 1) * T, bw)) * bpb
                rows.append(s..<e)
                if !changed, let a = a { changed = a[s..<e] != b[s..<e] }
            }
            if changed { dirty += 1; for r in rows { payload.append(contentsOf: UnsafeBufferPointer(rebasing: bb[r])) } }
        }}
    }
    return (payload, dirty, tw * th)
}
func compress(_ d: Data, _ algo: compression_algorithm) -> (Int, Double) {
    if d.isEmpty { return (0, 0) }
    var dst = [UInt8](repeating: 0, count: d.count + 4096)
    let t0 = Date()
    let n = d.withUnsafeBytes { compression_encode_buffer(&dst, dst.count, $0.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, algo) }
    return (n, Date().timeIntervalSince(t0) * 1000)
}

let (w, h, A) = loadRGBA(pathA)
let (_, _, B) = loadRGBA(pathB)
// scrolled version of A: shift up by 240 px (≈ one wheel flick at 2x), fill bottom with B rows
var S = [UInt8](repeating: 255, count: A.count)
let shift = 240
S.replaceSubrange(0..<((h - shift) * w * 4), with: A[(shift * w * 4)..<(h * w * 4)])
S.replaceSubrange(((h - shift) * w * 4)..<(h * w * 4), with: B[0..<(shift * w * 4)])
// small change: 600x40 px region (typing a line) altered
var Tn = A
for y in 1000..<1040 { for x in 800..<1400 { let i = (y * w + x) * 4; Tn[i] = 255 &- Tn[i]; Tn[i+1] = 255 &- Tn[i+1] } }

let texA = texFrom(w, h, A), texS = texFrom(w, h, S), texB = texFrom(w, h, B), texT = texFrom(w, h, Tn)
for bc7 in [true, false] {
    let name = bc7 ? "BC7m6" : "BC1"
    let bpb = bc7 ? 16 : 8
    let eA = encode(texA, bc7: bc7), eS = encode(texS, bc7: bc7), eB = encode(texB, bc7: bc7), eT = encode(texT, bc7: bc7)
    let dA = decode(eA.data, w: w, h: h, bc7: bc7)
    let (p, m) = psnr(A, dA)
    try! eA.data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)_A_linear.bin"))
    var hsum: UInt64 = 1469598103934665603
    for (i, v) in dA.enumerated() where i % 4 != 3 { hsum = (hsum ^ UInt64(v)) &* 1099511628211 }
    print("  decoded_rgb_fnv=\(String(hsum, radix: 16))")
    print(String(format: "%@ encode_gpu_ms=%.2f raw_frame_MB=%.2f PSNR_A=%.2fdB maxdiff=%d", name, eA.gpuMs, Double(eA.data.count) / 1e6, p, m))
    let (_, pB) = (0, psnr(B, decode(eB.data, w: w, h: h, bc7: bc7))); print(String(format: "  PSNR_B=%.2fdB", pB.0))
    for (label, prev, cur) in [("full_A", nil, eA.data), ("full_B", nil, eB.data), ("scroll240", eA.data, eS.data), ("switch_A_to_B", eA.data, eB.data), ("typing_600x40", eA.data, eT.data)] as [(String, Data?, Data)] {
        let (pl, dirty, total) = tileSet(prev, cur, w: w, h: h, bpb: bpb)
        let (l4, l4ms) = compress(pl, COMPRESSION_LZ4)
        let (lf, lfms) = compress(pl, COMPRESSION_LZFSE)
        print(String(format: "  %-14@ dirty=%4d/%d raw=%7.2fMB lz4=%6.2fMB (%.1fms) lzfse=%6.2fMB (%.1fms) -> gigabit_ms(lz4)=%.1f",
                     label, dirty, total, Double(pl.count) / 1e6, Double(l4) / 1e6, l4ms, Double(lf) / 1e6, lfms, Double(l4) / 110e6 * 1000))
        if label == "full_A" { try! pl.write(to: URL(fileURLWithPath: "\(outDir)/\(name)_A.bin")) }
    }
    // crops for visual inspection: source vs decoded, 800x500 region from several spots
    for (i, (cx, cy)) in [(200, 200), (2400, 1200), (3800, 2000)].enumerated() {
        let cw = 800, ch = 500
        var cs = [UInt8](), cd = [UInt8]()
        for y in cy..<(cy + ch) { let s = (y * w + cx) * 4; cs += A[s..<(s + cw * 4)]; cd += dA[s..<(s + cw * 4)] }
        savePNG("\(outDir)/crop\(i)_src.png", cw, ch, cs)
        savePNG("\(outDir)/crop\(i)_\(name).png", cw, ch, cd)
    }
}
