// Receiver-side probe (runs on iMac, Big Sur x86_64): LZ4 decode → BC texture upload → GPU decode → hash.
// usage: imacprobe <bc7|bc1> <linear.bin> <width> <height>
import Foundation
import Metal
import Compression

let a = CommandLine.arguments
let bc7 = a[1] == "bc7", raw = try! Data(contentsOf: URL(fileURLWithPath: a[2]))
let w = Int(a[3])!, h = Int(a[4])!
let dev = MTLCreateSystemDefaultDevice()!
print("device=\(dev.name) lowPower=\(dev.isLowPower)")
let src = """
#include <metal_stdlib>
using namespace metal;
kernel void readback(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::write> d [[texture(1)]], uint2 g [[thread_position_in_grid]]) {
  if (g.x >= d.get_width() || g.y >= d.get_height()) return; d.write(s.read(g), g); }
"""
let lib = try! dev.makeLibrary(source: src, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "readback")!)
let q = dev.makeCommandQueue()!

// compress locally to get a realistic LZ4 payload, then time decode
var comp = [UInt8](repeating: 0, count: raw.count + 4096)
let csize = raw.withUnsafeBytes { compression_encode_buffer(&comp, comp.count, $0.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4) }
var dec = [UInt8](repeating: 0, count: raw.count)
var t0 = Date()
var n = 0
for _ in 0..<10 { n = compression_decode_buffer(&dec, dec.count, comp, csize, nil, COMPRESSION_LZ4) }
let lz4ms = Date().timeIntervalSince(t0) * 100
print(String(format: "lz4 payload=%.2fMB decode_ms=%.2f ok=%d", Double(csize) / 1e6, lz4ms, n == raw.count ? 1 : 0))

let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: bc7 ? .bc7_rgbaUnorm : .bc1_rgba, width: w, height: h, mipmapped: false)
td.usage = [.shaderRead]
guard let tex = dev.makeTexture(descriptor: td) else { print("FAIL: cannot create BC texture"); exit(1) }
let bpr = (w + 3) / 4 * (bc7 ? 16 : 8)
t0 = Date()
for _ in 0..<10 { dec.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bpr) } }
print(String(format: "upload_full_frame_ms=%.2f", Date().timeIntervalSince(t0) * 100))
// partial upload: one 64x64 tile
t0 = Date()
for i in 0..<1000 { let tx = (i % 80) * 64, ty = ((i / 80) % 45) * 64
    dec.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(tx, ty, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress! + (ty / 4) * bpr + (tx / 4) * (bc7 ? 16 : 8), bytesPerRow: bpr) } }
print(String(format: "upload_one_tile_us=%.1f", Date().timeIntervalSince(t0) * 1000))
// re-upload full frame for hash
dec.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bpr) }

let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
od.usage = [.shaderWrite]; od.storageMode = .managed
let o = dev.makeTexture(descriptor: od)!
let cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
e.setComputePipelineState(pso); e.setTexture(tex, index: 0); e.setTexture(o, index: 1)
e.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
e.endEncoding()
let bl = cb.makeBlitCommandEncoder()!; bl.synchronize(resource: o); bl.endEncoding()
cb.commit(); cb.waitUntilCompleted()
print(String(format: "gpu_sample_full_frame_ms=%.2f", (cb.gpuEndTime - cb.gpuStartTime) * 1000))
var px = [UInt8](repeating: 0, count: w * h * 4)
px.withUnsafeMutableBytes { o.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
var hsum: UInt64 = 1469598103934665603
for (i, v) in px.enumerated() where i % 4 != 3 { hsum = (hsum ^ UInt64(v)) &* 1099511628211 }
print("decoded_rgb_fnv=\(String(hsum, radix: 16))")
