// Encode → diff-against-what-the-receiver-has → send, with one frame in flight.
import Foundation
import Metal
import Network
import Compression

func slog(_ s: String) { FileHandle.standardError.write(("[send] " + s + "\n").data(using: .utf8)!) }

final class BC7Encoder {
    let dev: MTLDevice
    let q: MTLCommandQueue
    let encPSO: MTLComputePipelineState
    let rbPSO: MTLComputePipelineState
    let w: Int, h: Int, bw: Int, bh: Int
    let out: MTLBuffer   // linear BC7 blocks of the most recent frame

    init(dev: MTLDevice, kernelSource: String, width: Int, height: Int) {
        self.dev = dev; q = dev.makeCommandQueue()!
        let lib = try! dev.makeLibrary(source: kernelSource, options: nil)
        encPSO = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "bc7_mode6")!)
        rbPSO = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "readback")!)
        w = width; h = height; bw = width / 4; bh = height / 4
        out = dev.makeBuffer(length: bw * bh * 16, options: .storageModeShared)!
    }

    /// Encode a full frame into `out`. Blocks until the GPU is done (≈1 ms at 5K on M3 Ultra).
    func encode(_ t: MTLTexture) {
        var bwU = UInt32(bw)
        let cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(encPSO)
        e.setTexture(t, index: 0); e.setBuffer(out, offset: 0, index: 0); e.setBytes(&bwU, length: 4, index: 1)
        e.dispatchThreads(MTLSize(width: bw, height: bh, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    }

    /// GPU-decode a linear BC7 buffer and hash its RGB (to compare with the receiver bit-exactly).
    func decodeHash(_ blocks: UnsafeRawPointer) -> UInt64 {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bc7_rgbaUnorm, width: w, height: h, mipmapped: false)
        td.usage = [.shaderRead]
        let t = dev.makeTexture(descriptor: td)!
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: blocks, bytesPerRow: bw * 16)
        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        od.usage = [.shaderWrite]; od.storageMode = .shared
        let o = dev.makeTexture(descriptor: od)!
        let cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(rbPSO); e.setTexture(t, index: 0); e.setTexture(o, index: 1)
        e.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { o.getBytes($0.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        return px.withUnsafeBytes { fnvRGB($0) }
    }
}

/// Owns the frame connection. All state is touched on `q` only.
final class FrameSender {
    let enc: BC7Encoder
    let q = DispatchQueue(label: "bcd.frames", qos: .userInteractive)
    let tilesX: Int, tilesY: Int
    var sent: [UInt8]                 // BC7 content the receiver currently has (linear)
    var receiverHasNothing = true
    var conn: MsgConn?
    var inFlight = false
    var dirtySinceSend = false        // a newer encode exists that was not yet diffed+sent
    var hasContent = false            // enc.out holds a real captured frame (never stream an empty buffer)
    var frameId: UInt32 = 0
    var lastCaptureTs: UInt64 = 0
    var sendTsById: [UInt32: UInt64] = [:]     // frameId → capture timestamp (sender clock)
    var clockOffset: Int64 = 0        // receiverClock - senderClock, from the best (lowest RTT) ping
    var bestRtt: UInt64 = .max
    var pendingDump: ((UInt64) -> Void)?
    // stats (1s window)
    var sFrames = 0, sTiles = 0, sWire = 0, sLat: [Double] = [], sAckRtt: [Double] = []
    var sentAtById: [UInt32: UInt64] = [:]

    init(enc: BC7Encoder) {
        self.enc = enc
        tilesX = enc.w / BCD.tilePx; tilesY = enc.h / BCD.tilePx
        sent = [UInt8](repeating: 0, count: enc.out.length)
    }

    func attach(_ c: MsgConn) {   // on q
        conn = c; inFlight = false; receiverHasNothing = true; dirtySinceSend = true
        bestRtt = .max
        c.onMessage = { [weak self] t, d in self?.q.async { self?.handle(t, d) } }
        trySend()   // push a full frame right away on (re)connect
    }

    /// Called after `enc.encode(...)` finished for a newly captured frame.
    func frameEncoded(captureTs: UInt64) {   // on q
        lastCaptureTs = captureTs
        hasContent = true
        dirtySinceSend = true
        trySend()
    }

    private func trySend() {
        guard let conn, hasContent, !inFlight, dirtySinceSend else { return }
        dirtySinceSend = false
        let bpr = enc.bw * 16                           // bytes per block row
        let tileRow = BCD.tileBlocks * 16               // 256 bytes of one tile within a block row
        let cur = enc.out.contents().assumingMemoryBound(to: UInt8.self)
        var raw = Data(); var count = 0
        sent.withUnsafeMutableBufferPointer { sp in
            let s = sp.baseAddress!
            for ty in 0..<tilesY { for tx in 0..<tilesX {
                var changed = receiverHasNothing
                if !changed {
                    for r in 0..<BCD.tileBlocks {
                        let o = (ty * BCD.tileBlocks + r) * bpr + tx * tileRow
                        if memcmp(cur + o, s + o, tileRow) != 0 { changed = true; break }
                    }
                }
                guard changed else { continue }
                count += 1
                var idx = UInt16(ty * tilesX + tx).littleEndian
                withUnsafeBytes(of: &idx) { raw.append(contentsOf: $0) }
                for r in 0..<BCD.tileBlocks {
                    let o = (ty * BCD.tileBlocks + r) * bpr + tx * tileRow
                    raw.append(cur + o, count: tileRow)
                    memcpy(s + o, cur + o, tileRow)
                }
            }}
        }
        receiverHasNothing = false
        guard count > 0 else { return }
        var comp = Data(count: raw.count + 4096)
        let clen = comp.withUnsafeMutableBytes { d in raw.withUnsafeBytes { r in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, d.count, r.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_LZ4) } }
        comp.count = clen
        frameId &+= 1
        var w = Writer()
        w.u32(frameId); w.u64(lastCaptureTs); w.u32(UInt32(count)); w.u32(UInt32(raw.count)); w.bytes(comp)
        sendTsById[frameId] = lastCaptureTs
        sentAtById[frameId] = nowNs()
        inFlight = true
        sFrames += 1; sTiles += count; sWire += w.d.count
        conn.send(.frame, w.d)
    }

    private func handle(_ t: MsgType, _ d: Data) {   // on q
        var r = Reader(d)
        switch t {
        case .hello:
            let v = r.u16(), w = r.u32(), h = r.u32()
            slog("receiver hello v\(v) \(w)x\(h)")
        case .ack:
            let fid = r.u32()
            if let s = sentAtById.removeValue(forKey: fid) { sAckRtt.append(Double(nowNs() - s) / 1e6) }
            inFlight = false
            trySend()
        case .presented:
            let fid = r.u32(), pts = r.u64()
            if let cap = sendTsById.removeValue(forKey: fid), bestRtt != .max {
                let presentLocal = Int64(pts) - clockOffset
                sLat.append(Double(presentLocal - Int64(cap)) / 1e6)
            }
            if sendTsById.count > 500 { sendTsById.removeAll() }
        case .pong:
            let t0 = r.u64(), tR = r.u64(), t1 = nowNs()
            let rtt = t1 - t0
            if rtt < bestRtt { bestRtt = rtt; clockOffset = Int64(tR) - Int64(t0 + rtt / 2) }
        case .dumpRes:
            let h = r.u64(); pendingDump?(h); pendingDump = nil
        default: break
        }
    }

    func ping() { q.async { var w = Writer(); w.u64(nowNs()); self.conn?.send(.ping, w.d) } }

    func requestDump(_ cb: @escaping (_ receiver: UInt64, _ local: UInt64) -> Void) {
        q.async {
            let local = self.sent.withUnsafeBytes { self.enc.decodeHash($0.baseAddress!) }
            self.pendingDump = { cb($0, local) }
            self.conn?.send(.dumpReq, Data())
        }
    }

    func logStats() {
        q.async {
            func med(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[a.count / 2] }
            func p90(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[min(a.count - 1, a.count * 9 / 10)] }
            if self.sFrames > 0 {
                slog(String(format: "window: frames=%d tiles=%d wire=%.2fMB ack_rtt_med=%.1fms capture→gpudone med=%.1fms p90=%.1fms (n=%d, ping_rtt=%.2fms)",
                            self.sFrames, self.sTiles, Double(self.sWire) / 1e6, med(self.sAckRtt), med(self.sLat), p90(self.sLat), self.sLat.count,
                            self.bestRtt == .max ? -1 : Double(self.bestRtt) / 1e6))
            }
            self.sFrames = 0; self.sTiles = 0; self.sWire = 0; self.sLat = []; self.sAckRtt = []
        }
    }
}

/// Connect a framed TCP connection to the receiver.
func connect(host: String, port: UInt16, queue: DispatchQueue, onReady: @escaping (MsgConn) -> Void, onClose: @escaping (String) -> Void) {
    let nc = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: MsgConn.tcpParams())
    let c = MsgConn(nc, queue: queue)
    c.onClose = onClose
    c.start { onReady(c) }
}
