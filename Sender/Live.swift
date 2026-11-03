// Live mode: virtual HiDPI display → ScreenCaptureKit → BC7 → receiver. Cursor on a second connection.
import AppKit
import Metal
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Network

final class VirtualDisplay {
    let display: CGVirtualDisplay
    var id: CGDirectDisplayID { display.displayID }

    init?(pointsW: Int, pointsH: Int, name: String) {
        let d = CGVirtualDisplayDescriptor()
        d.name = name
        d.vendorID = 0xBCD1; d.productID = 0x0001; d.serialNum = 0x2014; d.serialNumber = 0x2014
        d.maxPixelsWide = UInt32(pointsW * 2); d.maxPixelsHigh = UInt32(pointsH * 2)
        d.sizeInMillimeters = CGSize(width: 597, height: 336)       // 27-inch 16:9
        d.queue = DispatchQueue.main
        let onTerminate: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in slog("virtual display terminated by system") }
        d.terminationHandler = onTerminate
        guard let v = CGVirtualDisplay(descriptor: d) else { return nil }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = true
        s.modes = [CGVirtualDisplayMode(width: UInt(pointsW), height: UInt(pointsH), refreshRate: 60)!]
        guard v.apply(s) else { return nil }
        display = v
        selectHiDPIMode(pointsW: pointsW, pointsH: pointsH)
    }

    /// Pick the Retina (2x backing) variant; macOS may otherwise choose the blurry 1x one.
    func selectHiDPIMode(pointsW: Int, pointsH: Int) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        for _ in 0..<40 {
            if let cur = CGDisplayCopyDisplayMode(id), cur.width == pointsW, cur.pixelWidth == pointsW * 2 {
                slog("virtual display \(id) already HiDPI \(cur.width)x\(cur.height) px \(cur.pixelWidth)x\(cur.pixelHeight)")
                return
            }
            let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            if let m = modes.first(where: { $0.width == pointsW && $0.height == pointsH && $0.pixelWidth == pointsW * 2 }) {
                let r = CGDisplaySetDisplayMode(id, m, nil)
                slog("virtual display \(id) mode \(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight) set=\(r.rawValue)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        slog("WARNING: HiDPI mode not found for virtual display")
    }

    /// Place the virtual display directly left of the main display, top-aligned.
    func placeLeftOfMain() {
        let main = CGDisplayBounds(CGMainDisplayID())
        let me = CGDisplayBounds(id)
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayOrigin(cfg, id, Int32(main.minX - me.width), Int32(main.minY))
        let r = CGCompleteDisplayConfiguration(cfg, .forSession)
        slog("placed virtual display at \(CGDisplayBounds(id)) (r=\(r.rawValue))")
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let fs: FrameSender
    let dev: MTLDevice
    var stream: SCStream?
    var texCache: CVMetalTextureCache?
    let outQ = DispatchQueue(label: "bcd.capture", qos: .userInteractive)
    var frames = 0, idle = 0

    init(fs: FrameSender, dev: MTLDevice) {
        self.fs = fs; self.dev = dev
        super.init()
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &texCache)
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int) async throws {
        var scDisplay: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let scDisplay else { throw NSError(domain: "bcd", code: 1, userInfo: [NSLocalizedDescriptionKey: "virtual display not visible to ScreenCaptureKit"]) }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.width = width; c.height = height
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.queueDepth = 4
        c.colorSpaceName = CGColorSpace.sRGB
        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outQ)
        try await s.startCapture()
        stream = s
        slog("capture started \(width)x\(height)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        let ts = nowNs()
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete {
            idle += 1; return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb), let cache = texCache else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return }
        frames += 1
        let fs = self.fs
        fs.q.async {
            withExtendedLifetime((sb, cvTex)) {    // keep the IOSurface alive until encoded
                fs.enc.encode(tex)
            }
            fs.frameEncoded(captureTs: ts)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { slog("capture stopped: \(error)") }
}

/// Sends the system cursor's position/image (only while it is on the virtual display) at 120 Hz.
final class CursorSender {
    let q = DispatchQueue(label: "bcd.cursor", qos: .userInteractive)
    var conn: MsgConn?
    var displayID: CGDirectDisplayID      // 0 = no virtual display (touch on q)
    var timer: DispatchSourceTimer?
    var lastX: Float = -1, lastY: Float = -1, lastVis = false, lastImg: UInt32 = 0
    var sentImages = Set<UInt32>()

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    func attach(_ c: MsgConn) { q.async { self.conn = c; self.sentImages.removeAll(); self.lastX = -1 } }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .microseconds(8333), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }

    private func tick() {
        guard let conn, displayID != 0, let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(displayID)
        let vis = b.contains(loc)
        let x = Float(loc.x - b.minX), y = Float(loc.y - b.minY)
        var img = lastImg
        if vis, let cur = DispatchQueue.main.sync(execute: { NSCursor.currentSystem }) {
            img = imageId(cur)
            if !sentImages.contains(img), let msg = imageMsg(cur, id: img) { conn.send(.cursorImage, msg); sentImages.insert(img) }
        }
        if vis == lastVis && x == lastX && y == lastY && img == lastImg { return }
        lastVis = vis; lastX = x; lastY = y; lastImg = img
        var w = Writer(); w.f32(x); w.f32(y); w.u8(vis ? 1 : 0); w.u32(img)
        conn.send(.cursor, w.d)
    }

    private var idCache: [ObjectIdentifier: UInt32] = [:]
    private func imageId(_ c: NSCursor) -> UInt32 {
        // NSCursor.currentSystem returns a fresh object each call; hash the image bytes (cheap: cursors are tiny).
        guard let tiff = c.image.tiffRepresentation else { return 0 }
        var h: UInt32 = 2166136261
        for b in tiff { h = (h ^ UInt32(b)) &* 16777619 }
        h ^= UInt32(truncatingIfNeeded: Int(c.hotSpot.x * 7 + c.hotSpot.y * 131))
        return h == 0 ? 1 : h
    }
    private func imageMsg(_ c: NSCursor, id: UInt32) -> Data? {
        guard let tiff = c.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        var w = Writer()
        w.u32(id); w.f32(Float(c.hotSpot.x)); w.f32(Float(c.hotSpot.y))
        w.f32(Float(c.image.size.width)); w.f32(Float(c.image.size.height)); w.bytes(png)
        return w.d
    }
}

/// Session controller: find the iMac over the cable, create the virtual display only while it is connected,
/// forward screen sleep/wake, and keep the main display's rotation intact. Main thread only.
final class Controller {
    let pointsW = 2560, pointsH = 1440
    let enc: BC7Encoder
    let fs: FrameSender
    let cur: CursorSender
    var vd: VirtualDisplay?
    var cap: Capture?
    var endpoint: NWEndpoint?
    var browser: NWBrowser?
    var frameUp = false, cursorUp = false, connectingFrames = false, connectingCursor = false
    var teardownWork: DispatchWorkItem?
    let mainRotation = CGDisplayRotation(CGMainDisplayID())
    var mainPlacerSpec: String?

    init() {
        enc = BC7Encoder(dev: dev, kernelSource: kernelSrc, width: 2560 * 2, height: 1440 * 2)
        fs = FrameSender(enc: enc)
        cur = CursorSender(displayID: 0)
        mainPlacerSpec = Controller.currentMainPlacerSpec()
    }

    func start() {
        if let h = opt("--host") {
            endpoint = .hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: port)!)
            connectAll()
        } else {
            let p = NWParameters(); p.requiredInterfaceType = .wiredEthernet
            let b = NWBrowser(for: .bonjour(type: "_bcdisplay._tcp", domain: nil), using: p)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // pin the service to the wired interface (results also come back scoped to Wi-Fi)
                    var ep: NWEndpoint?
                    for r in results {
                        guard case let .service(name, type, domain, _) = r.endpoint,
                              let wired = r.interfaces.first(where: { $0.type == .wiredEthernet }) else { continue }
                        ep = .service(name: name, type: type, domain: domain, interface: wired)
                        break
                    }
                    if let ep, ep != self.endpoint { slog("found receiver \(ep) via wired"); self.endpoint = ep; self.connectAll() }
                    if ep == nil, self.endpoint != nil { slog("receiver not visible on a wired interface") }
                }
            }
            b.stateUpdateHandler = { st in slog("browser \(st)") }
            b.start(queue: .main)
            browser = b
        }
        cur.start()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            slog("screens did sleep"); self?.fs.q.async { self?.fs.conn?.send(.displaySleep, Data()) } }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            slog("screens did wake"); self?.fs.q.async { self?.fs.conn?.send(.displayWake, Data()) } }
    }

    func connectAll() { connectFrames(); connectCursor() }

    func params() -> NWParameters {
        let p = MsgConn.tcpParams()
        if opt("--host") == nil { p.requiredInterfaceType = .wiredEthernet }
        return p
    }

    func connectFrames() {
        guard let ep = endpoint, !frameUp, !connectingFrames else { return }
        connectingFrames = true
        let c = MsgConn(NWConnection(to: ep, using: params()), queue: fs.q)
        c.onClose = { [weak self] why in DispatchQueue.main.async {
            guard let self else { return }
            slog("frame connection down: \(why)")
            self.connectingFrames = false
            let wasUp = self.frameUp
            self.frameUp = false
            self.fs.q.async { if self.fs.conn === c { self.fs.conn = nil } }
            if wasUp { self.scheduleTeardown() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.connectFrames() }
        }}
        c.start { [weak self] in DispatchQueue.main.async {
            guard let self else { return }
            self.connectingFrames = false; self.frameUp = true
            slog("frame connection up")
            self.teardownWork?.cancel(); self.teardownWork = nil
            self.ensureSession()
            self.fs.q.async { self.fs.attach(c) }
        }}
    }

    func connectCursor() {
        guard let ep = endpoint, !cursorUp, !connectingCursor else { return }
        connectingCursor = true
        let c = MsgConn(NWConnection(to: ep, using: params()), queue: cur.q)
        c.onClose = { [weak self] _ in DispatchQueue.main.async {
            guard let self else { return }
            self.connectingCursor = false; self.cursorUp = false
            self.cur.q.async { if self.cur.conn === c { self.cur.conn = nil } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.connectCursor() }
        }}
        c.start { [weak self] in DispatchQueue.main.async {
            guard let self else { return }
            self.connectingCursor = false; self.cursorUp = true
            c.onMessage = { _, _ in }
            self.cur.attach(c)
        }}
    }

    var askedForCapture = false
    var captureAllowed = false
    var probing = false
    func ensureSession() {
        if vd != nil || probing { return }
        // Don't put up a black virtual display while we can't capture; wait for the Screen Recording grant.
        // CGPreflightScreenCaptureAccess() proved unreliable here, so probe ScreenCaptureKit itself.
        if !captureAllowed {
            probing = true
            Task {
                let ok = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) != nil
                await MainActor.run {
                    self.probing = false
                    if ok { self.captureAllowed = true; slog("Screen Recording permission OK"); self.ensureSession(); return }
                    if !self.askedForCapture { self.askedForCapture = true; slog("no Screen Recording permission yet; requesting"); _ = CGRequestScreenCaptureAccess() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in if let self, self.frameUp { self.ensureSession() } }
                }
            }
            return
        }
        guard let v = VirtualDisplay(pointsW: pointsW, pointsH: pointsH, name: "iMac 5K (bcd)") else { slog("cannot create virtual display"); return }
        vd = v
        v.placeLeftOfMain()
        cur.q.async { self.cur.displayID = v.id }
        let c = Capture(fs: fs, dev: dev)
        cap = c
        Task {
            do { try await c.start(displayID: v.id, width: self.pointsW * 2, height: self.pointsH * 2) }
            catch {
                // a fresh TCC grant is often only honoured after relaunch; launchd restarts us (non-zero exit)
                slog("capture failed: \(error); exiting so launchd relaunches"); exit(5)
            }
        }
        checkMainRotation()
    }

    func scheduleTeardown() {
        teardownWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.teardown() }
        teardownWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
        slog("receiver gone; removing virtual display in 15s unless it comes back")
    }

    func teardown() {
        guard let v = vd else { return }
        slog("removing virtual display \(v.id)")
        if let s = cap?.stream { Task { try? await s.stopCapture() } }
        cap = nil
        vd = nil
        fs.q.async { self.fs.hasContent = false }
        cur.q.async { self.cur.displayID = 0 }
        checkMainRotation()
    }

    /// Adding/removing a display has been seen to flip the main display's rotation; undo that if it happens.
    func checkMainRotation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let now = CGDisplayRotation(CGMainDisplayID())
            guard now != self.mainRotation, let spec = self.mainPlacerSpec else { return }
            slog("main display rotation changed \(self.mainRotation)→\(now); restoring with displayplacer")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/displayplacer")
            p.arguments = [spec]
            try? p.run()
        }
    }

    static func currentMainPlacerSpec() -> String? {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/displayplacer")
        p.arguments = ["list"]; p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let last = out.split(separator: "\n").last(where: { $0.hasPrefix("displayplacer ") }) else { return nil }
        // each screen spec is a quoted "id:... origin:(0,0) ..." chunk; keep the main one
        return last.split(separator: "\"").map(String.init).first { $0.contains("origin:(0,0)") }
    }
}

func runLive() {
    // single instance (launchd + a manual run must not both create a display)
    let lockDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/bcd")
    try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
    let fd = open(lockDir.appendingPathComponent("sender.lock").path, O_CREAT | O_RDWR, 0o644)
    if fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0 { slog("another bcd-sender is running; exiting"); exit(0) }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let ctl = Controller()
    ctl.start()
    let pinger = Timer(timeInterval: 1, repeats: true) { _ in ctl.fs.ping() }
    let stats = Timer(timeInterval: 30, repeats: true) { _ in ctl.fs.logStats() }
    RunLoop.main.add(pinger, forMode: .common); RunLoop.main.add(stats, forMode: .common)
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { slog("signal \(sig), exiting"); exit(0) }   // dropping the CGVirtualDisplay removes it
        src.resume()
        signalSources.append(src)
    }
    withExtendedLifetime((ctl, fd)) { NSApp.run() }
}
var signalSources: [DispatchSourceSignal] = []
