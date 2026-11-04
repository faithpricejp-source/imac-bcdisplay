// Wire protocol shared by sender and receiver. Little-endian.
// Frame header: magic u32 | type u8 | len u32 | payload[len]
import Foundation
import Network

enum BCD {
    static let magic: UInt32 = 0x3144_4342 // "BCD1"
    static let port: UInt16 = 47_900
    static let version: UInt16 = 1
    static let tilePx = 64                // tile edge in pixels
    static let tileBlocks = tilePx / 4    // 16 BC blocks per tile edge
    static let blockBytes = 16            // BC7
    static let tileBytes = tileBlocks * tileBlocks * blockBytes // 4096
}

enum MsgType: UInt8 {
    case hello = 1        // R→S: version u16, width u32, height u32, pointsW u32, pointsH u32
    case frame = 2        // S→R: frameId u32, captureTs u64, tileCount u32, rawLen u32, lz4 blob
    case cursor = 3       // S→R: x f32, y f32 (points, top-left origin), visible u8, imageId u32
    case cursorImage = 4  // S→R: imageId u32, hotX f32, hotY f32, wPt f32, hPt f32, png...
    case ping = 5         // S→R: t0 u64 (sender clock)
    case pong = 6         // R→S: t0 u64, tR u64 (receiver clock)
    case ack = 7          // R→S: frameId u32, recvTs u64, appliedTs u64 (receiver clock)
    case presented = 8    // R→S: frameId u32, presentTs u64
    case dumpReq = 9      // S→R: (empty) ask receiver to hash its current texture decode
    case dumpRes = 10     // R→S: fnv u64
    case displaySleep = 11 // S→R: sender's screens went to sleep
    case displayWake = 12  // S→R: sender's screens woke up
}

/// Monotonic nanoseconds (mach absolute time). Same base as CACurrentMediaTime.
@inline(__always) func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

struct Writer {
    var d = Data()
    mutating func u8(_ v: UInt8) { d.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ b: Data) { d.append(b) }
}

struct Reader {
    let d: Data
    var o: Int
    init(_ d: Data) { self.d = d; self.o = d.startIndex }
    mutating func u8() -> UInt8 { defer { o += 1 }; return d[o] }
    mutating func u16() -> UInt16 { var v: UInt16 = 0; withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: d[o..<o + 2]) }; o += 2; return UInt16(littleEndian: v) }
    mutating func u32() -> UInt32 { var v: UInt32 = 0; withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: d[o..<o + 4]) }; o += 4; return UInt32(littleEndian: v) }
    mutating func u64() -> UInt64 { var v: UInt64 = 0; withUnsafeMutableBytes(of: &v) { $0.copyBytes(from: d[o..<o + 8]) }; o += 8; return UInt64(littleEndian: v) }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
    mutating func rest() -> Data { defer { o = d.endIndex }; return d.subdata(in: o..<d.endIndex) }
}

func packMsg(_ t: MsgType, _ payload: Data) -> Data {
    var w = Writer()
    w.u32(BCD.magic); w.u8(t.rawValue); w.u32(UInt32(payload.count)); w.bytes(payload)
    return w.d
}

/// Framed message transport over an NWConnection (TCP, no-delay).
final class MsgConn {
    let conn: NWConnection
    let queue: DispatchQueue
    var onMessage: ((MsgType, Data) -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false
    var lastRx = nowNs()          // last time any message arrived (watchdogs read this on the conn's queue)
    var sawPing = false           // peer pings us (the sender's frame connection does, every second)

    init(_ conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn; self.queue = queue
    }

    static func tcpParams() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2        // dead peers (killed process, pulled cable) are noticed in ~5 s
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.serviceClass = .interactiveVideo
        return p
    }

    /// `connectTimeout`: give up if not ready by then. A `.service` endpoint whose Bonjour record can't be
    /// resolved (e.g. across Mac sleep) otherwise sits in `.preparing` forever and never reports failure.
    func start(connectTimeout: TimeInterval? = nil, onReady: (() -> Void)? = nil) {
        var ready = false
        if let t = connectTimeout {
            queue.asyncAfter(deadline: .now() + t) { [weak self] in
                if !ready { self?.close("connect timeout after \(Int(t))s") }
            }
        }
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready: ready = true; onReady?(); self.readHeader()
            case .failed(let e): self.close("failed: \(e)")
            case .cancelled: self.close("cancelled")
            case .waiting(let e): self.close("waiting: \(e)")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func close(_ why: String) {
        if closed { return }
        closed = true
        conn.cancel()
        onClose?(why)
    }

    func send(_ t: MsgType, _ payload: Data, completion: (() -> Void)? = nil) {
        conn.send(content: packMsg(t, payload), completion: .contentProcessed { [weak self] err in
            if let err { self?.close("send: \(err)") }
            completion?()
        })
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] data, _, done, err in
            guard let self else { return }
            if let err { self.close("recv: \(err)"); return }
            guard let data, data.count == 9 else { self.close(done ? "eof" : "short header"); return }
            var r = Reader(data)
            guard r.u32() == BCD.magic, let t = MsgType(rawValue: r.u8()) else { self.close("bad header"); return }
            let len = Int(r.u32())
            self.lastRx = nowNs()
            if t == .ping { self.sawPing = true }
            if len == 0 { self.onMessage?(t, Data()); self.readHeader(); return }
            self.readBody(t, len)
        }
    }

    private func readBody(_ t: MsgType, _ len: Int) {
        conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, done, err in
            guard let self else { return }
            if let err { self.close("recv: \(err)"); return }
            guard let data, data.count == len else { self.close(done ? "eof" : "short body"); return }
            self.lastRx = nowNs()
            self.onMessage?(t, data)
            self.readHeader()
        }
    }
}

/// FNV-1a over RGB of an RGBA8 buffer (alpha ignored) — used to compare decodes bit-exactly.
func fnvRGB(_ px: UnsafeRawBufferPointer) -> UInt64 {
    var h: UInt64 = 1469598103934665603
    let b = px.bindMemory(to: UInt8.self)
    var i = 0
    while i < b.count {
        h = (h ^ UInt64(b[i])) &* 1099511628211
        h = (h ^ UInt64(b[i + 1])) &* 1099511628211
        h = (h ^ UInt64(b[i + 2])) &* 1099511628211
        i += 4
    }
    return h
}
