// bcd-receiver: shows a BC7 tile stream full-screen. Runs on the iMac (x86_64, macOS 11+).
// Flags: --headless (no window; loopback tests) --windowed (small window) --port N --size WxH (headless texture size)
import AppKit
import Metal
import MetalKit
import Network
import Compression
import IOKit.pwr_mgt

let argv = CommandLine.arguments
func flag(_ n: String) -> Bool { argv.contains(n) }
func opt(_ n: String) -> String? { argv.firstIndex(of: n).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
let headless = flag("--headless"), windowed = flag("--windowed")
let port = UInt16(opt("--port") ?? "") ?? BCD.port
func log(_ s: String) { FileHandle.standardError.write(("[recv] " + s + "\n").data(using: .utf8)!) }

let shaderSrc = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
}
fragment float4 fmain(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, in.uv);
}
kernel void readback(texture2d<float, access::read> s [[texture(0)]], texture2d<float, access::write> d [[texture(1)]], uint2 g [[thread_position_in_grid]]) {
    if (g.x >= d.get_width() || g.y >= d.get_height()) return; d.write(s.read(g), g);
}
"""

final class Receiver: NSObject, MTKViewDelegate {
    let dev = MTLCreateSystemDefaultDevice()!
    lazy var queue = dev.makeCommandQueue()!
    var tex: MTLTexture!
    var texW = 0, texH = 0, tilesX = 0
    var pointsW = 0, pointsH = 0
    var view: MTKView?
    var renderPSO: MTLRenderPipelineState?
    var samplerNearest: MTLSamplerState!, samplerLinear: MTLSamplerState!
    var readbackPSO: MTLComputePipelineState!
    var lastCB: MTLCommandBuffer?
    let netQ = DispatchQueue(label: "bcd.net", qos: .userInteractive)
    var listener: NWListener?
    var conns: [ObjectIdentifier: MsgConn] = [:]   // touched on netQ only
    var frameConn: MsgConn?                          // connection that last sent a frame
    var scratch = [UInt8]()
    var pendingPresentId: UInt32 = 0
    // stats
    var statFrames = 0, statTiles = 0, statBytes = 0, statApplyNs: UInt64 = 0, statPresented = 0
    var statDraws = 0, statNoDrawable = 0, statPresentZero = 0, statGpuDoneNs: UInt64 = 0
    // cursor
    var cursors: [UInt32: NSCursor] = [:]
    var curImageId: UInt32 = 0
    var cursorHidden = false
    // session: window is shown only while a sender streams to us
    var onActivate: (() -> Void)?
    var onDeactivate: (() -> Void)?
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var active = false          // main thread

    func setup(width: Int, height: Int, pointsW: Int, pointsH: Int) {
        texW = width; texH = height; tilesX = width / BCD.tilePx
        self.pointsW = pointsW; self.pointsH = pointsH
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bc7_rgbaUnorm, width: width, height: height, mipmapped: false)
        td.usage = [.shaderRead]
        tex = dev.makeTexture(descriptor: td)!
        // start black: BC7 mode 6 block with all-zero endpoints, alpha 255 handled by opaque render
        let lib = try! dev.makeLibrary(source: shaderSrc, options: nil)
        readbackPSO = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "readback")!)
        let sd = MTLSamplerDescriptor(); sd.minFilter = .nearest; sd.magFilter = .nearest
        samplerNearest = dev.makeSamplerState(descriptor: sd)
        sd.minFilter = .linear; sd.magFilter = .linear
        samplerLinear = dev.makeSamplerState(descriptor: sd)
        if let v = view {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "vmain"); pd.fragmentFunction = lib.makeFunction(name: "fmain")
            pd.colorAttachments[0].pixelFormat = v.colorPixelFormat
            renderPSO = try! dev.makeRenderPipelineState(descriptor: pd)
        }
        log("texture \(width)x\(height) points \(pointsW)x\(pointsH) device=\(dev.name)")
    }

    // MARK: network
    func listen() {
        let params = MsgConn.tcpParams()
        params.allowLocalEndpointReuse = true
        listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener!.service = NWListener.Service(name: Host.current().localizedName ?? "iMac", type: "_bcdisplay._tcp")
        listener!.newConnectionHandler = { [weak self] nc in self?.accept(nc) }
        listener!.stateUpdateHandler = { st in log("listener \(st)") }
        listener!.start(queue: netQ)
        // watchdog: a pinging (frame) connection that goes quiet for 5 s is dead even if TCP never said so
        let wd = DispatchSource.makeTimerSource(queue: netQ)
        wd.schedule(deadline: .now() + 2, repeating: 2)
        wd.setEventHandler { [weak self] in
            guard let self else { return }
            let now = nowNs()
            for c in self.conns.values where c.sawPing && now - c.lastRx > 5_000_000_000 { c.close("watchdog: silent for 5s") }
        }
        wd.resume(); watchdog = wd
    }
    var watchdog: DispatchSourceTimer?

    func accept(_ nc: NWConnection) {
        let c = MsgConn(nc, queue: netQ)
        conns[ObjectIdentifier(c)] = c
        log("connection from \(nc.endpoint) (open: \(conns.count))")
        c.onClose = { [weak self, weak c] why in
            log("connection closed: \(why)")
            guard let self, let c else { return }
            self.conns[ObjectIdentifier(c)] = nil
            if self.frameConn === c {
                self.frameConn = nil
                for o in self.conns.values where !o.sawPing { o.close("frame connection gone") }   // stale cursor conns
            }
            if self.conns.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let empty = self.netQ.sync { self.conns.isEmpty }
                    if empty && self.active { self.active = false; self.showCursor(true); self.onDeactivate?() }
                }
            }
        }
        c.onMessage = { [weak self, weak c] t, d in if let self, let c { self.handle(t, d, from: c) } }
        c.start { [weak self] in
            guard let self else { return }
            var w = Writer()
            w.u16(BCD.version); w.u32(UInt32(self.texW)); w.u32(UInt32(self.texH)); w.u32(UInt32(self.pointsW)); w.u32(UInt32(self.pointsH))
            c.send(.hello, w.d)
        }
    }

    func handle(_ t: MsgType, _ d: Data, from conn: MsgConn) {   // on netQ
        switch t {
        case .ping:
            var r = Reader(d); let t0 = r.u64()
            var w = Writer(); w.u64(t0); w.u64(nowNs()); conn.send(.pong, w.d)
        case .frame:
            let recvTs = nowNs()
            var r = Reader(d)
            let fid = r.u32(); _ = r.u64(); let count = Int(r.u32()); let rawLen = Int(r.u32())
            let blob = r.rest()
            var aw = Writer(); aw.u32(fid); aw.u64(recvTs); aw.u64(recvTs); conn.send(.ack, aw.d)
            var raw = Data(count: rawLen)
            let n = raw.withUnsafeMutableBytes { dst in
                blob.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, rawLen,
                                              src.bindMemory(to: UInt8.self).baseAddress!, blob.count, nil, COMPRESSION_LZ4)
                }
            }
            guard n == rawLen else { log("lz4 decode failed \(n)/\(rawLen)"); conn.close("bad frame"); return }
            frameConn = conn
            DispatchQueue.main.async { self.apply(fid, count, raw, recvTs, wire: d.count, conn: conn) }
        case .cursor:
            var r = Reader(d)
            let x = r.f32(), y = r.f32(), vis = r.u8() != 0, img = r.u32()
            DispatchQueue.main.async { self.moveCursor(x, y, vis, img) }
        case .cursorImage:
            var r = Reader(d)
            let id = r.u32(), hx = r.f32(), hy = r.f32(), w = r.f32(), h = r.f32()
            let png = r.rest()
            DispatchQueue.main.async {
                guard let img = NSImage(data: png) else { return }
                img.size = NSSize(width: CGFloat(w), height: CGFloat(h))
                self.cursors[id] = NSCursor(image: img, hotSpot: NSPoint(x: CGFloat(hx), y: CGFloat(hy)))
                if id == self.curImageId, !headless { self.cursors[id]?.set() }
            }
        case .displaySleep:
            DispatchQueue.main.async { self.onSleep?() }
        case .displayWake:
            DispatchQueue.main.async { self.onWake?() }
        case .dumpReq:
            DispatchQueue.main.async { self.dump(conn) }
        default:
            log("unexpected msg \(t)")
        }
    }

    // MARK: apply + draw (main thread)
    func apply(_ fid: UInt32, _ count: Int, _ raw: Data, _ recvTs: UInt64, wire: Int, conn: MsgConn) {
        if !active { active = true; onActivate?() }
        let t0 = nowNs()
        lastCB?.waitUntilCompleted()   // GPU must not be sampling while we overwrite tiles
        let rec = 2 + BCD.tileBytes
        raw.withUnsafeBytes { p in
            let base = p.baseAddress!
            for i in 0..<count {
                let o = i * rec
                let idx = Int(base.load(fromByteOffset: o, as: UInt16.self).littleEndian)
                let tx = (idx % tilesX) * BCD.tilePx, ty = (idx / tilesX) * BCD.tilePx
                tex.replace(region: MTLRegionMake2D(tx, ty, BCD.tilePx, BCD.tilePx), mipmapLevel: 0,
                            withBytes: base + o + 2, bytesPerRow: BCD.tileBlocks * BCD.blockBytes)
            }
        }
        let appliedTs = nowNs()
        _ = recvTs
        statFrames += 1; statTiles += count; statBytes += wire; statApplyNs += appliedTs - t0
        pendingPresentId = fid
        view?.draw()
    }

    func draw(in view: MTKView) {
        statDraws += 1
        guard let pso = renderPSO, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { statNoDrawable += 1; return }
        enc.setRenderPipelineState(pso)
        enc.setFragmentTexture(tex, index: 0)
        let exact = Int(view.drawableSize.width) == texW && Int(view.drawableSize.height) == texH
        enc.setFragmentSamplerState(exact ? samplerNearest : samplerLinear, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let fid = pendingPresentId
        drawable.addPresentedHandler { [weak self] d in
            guard let self else { return }
            guard d.presentedTime > 0 else { self.netQ.async { self.statPresentZero += 1 }; return }
            self.netQ.async { self.statPresented += 1 }
        }
        cb.present(drawable)
        let t0 = nowNs()
        cb.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let done = nowNs()
            self.netQ.async { var w = Writer(); w.u32(fid); w.u64(done); self.frameConn?.send(.presented, w.d) }
            DispatchQueue.main.async { self.statGpuDoneNs += done - t0 }
        }
        cb.commit()
        lastCB = cb
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { log("drawable \(size)") }

    func dump(_ conn: MsgConn) {
        let px = readback()
        let h = px.withUnsafeBytes { fnvRGB($0) }
        log("dump fnv=\(String(h, radix: 16))")
        var w = Writer(); w.u64(h); conn.send(.dumpRes, w.d)
    }

    /// Debug: `kill -USR1 <pid>` writes the current decoded texture to ~/Library/Logs/bcd/snap.png.
    func snapshotPNG() {
        var px = readback()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let img = px.withUnsafeMutableBytes { b -> CGImage? in
            CGContext(data: b.baseAddress, width: texW, height: texH, bitsPerComponent: 8, bytesPerRow: texW * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let img, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { log("snapshot failed"); return }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/bcd/snap.png")
        try? png.write(to: url)
        log("snapshot written \(texW)x\(texH)")
    }

    func readback() -> [UInt8] {
        lastCB?.waitUntilCompleted()
        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: texW, height: texH, mipmapped: false)
        od.usage = [.shaderWrite]; od.storageMode = .managed
        let o = dev.makeTexture(descriptor: od)!
        let cb = queue.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(readbackPSO); e.setTexture(tex, index: 0); e.setTexture(o, index: 1)
        e.dispatchThreads(MTLSize(width: texW, height: texH, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        e.endEncoding()
        let bl = cb.makeBlitCommandEncoder()!; bl.synchronize(resource: o); bl.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: texW * texH * 4)
        px.withUnsafeMutableBytes { o.getBytes($0.baseAddress!, bytesPerRow: texW * 4, from: MTLRegionMake2D(0, 0, texW, texH), mipmapLevel: 0) }
        return px
    }

    // MARK: cursor (hardware cursor of this Mac, driven by the sender)
    func showCursor(_ show: Bool) {
        if headless { return }
        if show && cursorHidden { NSCursor.unhide(); cursorHidden = false }
        if !show && !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }
    func moveCursor(_ x: Float, _ y: Float, _ visible: Bool, _ img: UInt32) {
        if headless || !active { return }
        showCursor(visible)
        guard visible else { return }
        if img != curImageId { curImageId = img; cursors[img]?.set() }
        let scr = NSScreen.screens[0].frame   // global top-left origin == (0,0) for the main screen
        let sx = CGFloat(x) * scr.width / CGFloat(max(pointsW, 1)), sy = CGFloat(y) * scr.height / CGFloat(max(pointsH, 1))
        CGWarpMouseCursorPosition(CGPoint(x: sx, y: sy))
    }

    func logStats() {
        let fps = statFrames, tiles = statTiles, mb = Double(statBytes) / 1e6
        let applyMs = statFrames > 0 ? Double(statApplyNs) / Double(statFrames) / 1e6 : 0
        let gpuMs = statDraws > 0 ? Double(statGpuDoneNs) / Double(statDraws) / 1e6 : 0
        let (pres, pzero) = netQ.sync { () -> (Int, Int) in defer { statPresented = 0; statPresentZero = 0 }; return (statPresented, statPresentZero) }
        if fps > 0 || statDraws > 0 {
            log(String(format: "30s: frames=%d draws=%d nodrawable=%d presented=%d present0=%d gpu_done_avg=%.2fms tiles=%d wire=%.2fMB apply_avg=%.2fms",
                       fps, statDraws, statNoDrawable, pres, pzero, gpuMs, tiles, mb, applyMs))
        }
        statFrames = 0; statTiles = 0; statBytes = 0; statApplyNs = 0
        statDraws = 0; statNoDrawable = 0; statGpuDoneNs = 0
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let r = Receiver()
    var snapSource: DispatchSourceSignal?
    var window: NSWindow?
    var noSleep: IOPMAssertionID = 0
    var hasNoSleep = false
    var userActivity: IOPMAssertionID = 0
    var wakeCheck: DispatchWorkItem?
    var userSessionActive = true
    var sessionRestore: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        var w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        var pw = Int(screen.frame.width), ph = Int(screen.frame.height)
        if headless || windowed, let s = opt("--size") {
            let parts = s.split(separator: "x").compactMap { Int($0) }
            w = parts[0]; h = parts[1]; pw = w / 2; ph = h / 2
        }
        if !headless {
            let frame = windowed ? NSRect(x: 100, y: 100, width: 1280, height: 720) : screen.frame
            let win = NSWindow(contentRect: frame, styleMask: windowed ? [.titled, .resizable] : [.borderless], backing: .buffered, defer: false, screen: screen)
            let v = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: r.dev)
            v.colorPixelFormat = .bgra8Unorm
            v.framebufferOnly = true
            v.isPaused = true
            v.enableSetNeedsDisplay = false
            v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            v.delegate = r
            win.contentView = v
            win.backgroundColor = .black
            win.disableCursorRects()
            win.isReleasedWhenClosed = false
            r.view = v
            window = win
            r.onActivate = { [weak self] in self?.activate() }
            r.onDeactivate = { [weak self] in self?.deactivate() }
            r.onSleep = { [weak self] in self?.sleepDisplay() }
            r.onWake = { [weak self] in self?.wakeDisplay() }
        }
        r.setup(width: w, height: h, pointsW: pw, pointsH: ph)
        if let v = r.view { log("drawable \(v.drawableSize)") }
        r.listen()
        signal(SIGUSR1, SIG_IGN)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1.setEventHandler { [weak self] in self?.r.snapshotPNG() }
        usr1.resume(); snapSource = usr1
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumeUserSession("session active")
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspendUserSession()
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.resumeUserSession("screen unlocked")
        }
        distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.suspendUserSession()
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.r.logStats() }
    }

    func suspendUserSession() {
        userSessionActive = false
        sessionRestore?.cancel(); sessionRestore = nil
    }

    func resumeUserSession(_ reason: String) {
        userSessionActive = true
        restoreSession(reason)
    }

    func restoreSession(_ reason: String) {
        sessionRestore?.cancel()
        let restore = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionRestore = nil
            guard self.userSessionActive, self.r.active, !headless else { return }
            self.activate()
            self.r.view?.draw()
            log("restored stream window after \(reason): visible=\(self.window?.isVisible ?? false)")
        }
        sessionRestore = restore
        // Let loginwindow finish giving the user's GUI session back before ordering our window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: restore)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreSession("reopen")
        return true
    }

    func takeNoSleep(_ on: Bool) {
        if on && !hasNoSleep {
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "bcd-receiver showing remote display" as CFString, &noSleep)
            hasNoSleep = true
        } else if !on && hasNoSleep {
            IOPMAssertionRelease(noSleep); hasNoSleep = false
        }
    }

    func activate() {
        guard userSessionActive else { return }
        log("session active: taking over the screen")
        wakeDisplay()
        if !windowed {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            CGAssociateMouseAndMouseCursorPosition(0)   // local mouse must not fight the remote cursor
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        window?.deminiaturize(nil)
        // above every local app window (e.g. a remote-desktop client window that comes forward), so nothing on the iMac
        // can cover the stream — that hid the Mac Studio Dock at the bottom edge (2026-11-03)
        if !windowed { window?.level = .screenSaver }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.logWindowStack() }
    }

    /// Debug: where our window really is, and which on-screen windows sit at or above it.
    func logWindowStack() {
        guard let win = window else { return }
        log("window frame=\(win.frame) level=\(win.level.rawValue) screen=\(win.screen?.frame ?? .zero) visible=\(win.screen?.visibleFrame ?? .zero)")
        let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in l.prefix(15) {
            let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            log("  win layer=\(w[kCGWindowLayer as String] ?? "-") owner=\(w[kCGWindowOwnerName as String] ?? "-") bounds=\(b)")
        }
    }

    func deactivate() {
        log("session ended: giving the screen back")
        sessionRestore?.cancel(); sessionRestore = nil
        cancelWake()
        window?.orderOut(nil)
        NSApp.presentationOptions = []
        CGAssociateMouseAndMouseCursorPosition(1)
        NSApp.setActivationPolicy(.accessory)
        takeNoSleep(false)
    }

    func sleepDisplay() {
        log("sender screens asleep: sleeping display")
        cancelWake()
        takeNoSleep(false)
        let wrangler = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler")
        if wrangler != 0 { IORegistryEntrySetCFProperty(wrangler, "IORequestIdle" as CFString, kCFBooleanTrue); IOObjectRelease(wrangler) }
    }

    func wakeDisplay() {
        wakeCheck?.cancel()
        declareActivity()
        takeNoSleep(true)
        // IORequestIdle is asynchronous: a preceding sleep can finish AFTER the first wake.
        // Verify the physical panel rather than treating GPU frame completion as display wake.
        checkWake(remaining: 20)
    }

    func declareActivity() {
        let result = IOPMAssertionDeclareUserActivity("bcd-receiver wake" as CFString,
                                                    kIOPMUserActiveLocal, &userActivity)
        if result != kIOReturnSuccess { log("display wake request failed: \(result)") }
    }

    func checkWake(remaining: Int) {
        let check = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let wrangler = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler")
            var state: Int?
            if wrangler != 0 {
                let properties = IORegistryEntryCreateCFProperty(wrangler, "IOPowerManagement" as CFString,
                                                                kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                state = properties?["CurrentPowerState"] as? Int
                IOObjectRelease(wrangler)
            }
            if let state, state < 4 { self.declareActivity() }
            if remaining > 1 { self.checkWake(remaining: remaining - 1) }
            else {
                self.wakeCheck = nil
                log("display wake verification: power=\(state.map(String.init) ?? "unknown")")
            }
        }
        wakeCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
    }

    func cancelWake() {
        wakeCheck?.cancel(); wakeCheck = nil
        if userActivity != 0 { IOPMAssertionRelease(userActivity); userActivity = 0 }
    }

    func applicationWillTerminate(_ n: Notification) {
        CGAssociateMouseAndMouseCursorPosition(1)
        r.showCursor(true)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // invisible until a sender connects
let menu = NSMenu(), appItem = NSMenuItem()
menu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit bcd-receiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
app.mainMenu = menu
let delegate = AppDelegate()
app.delegate = delegate
#if RECEIVER_SESSION_TEST
scheduleReceiverSessionTests(app: app, delegate: delegate)
#endif
app.run()
