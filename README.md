# imac-bcdisplay

Use a **2014–2015 Retina 5K iMac** (no Target Display Mode, no HEVC hardware decoder) as a native 5K extended display for an Apple Silicon Mac. It is free and runs over a single Ethernet cable.

[中文说明见下方](#中文)

## Why

Tools that stream a Mac's screen to an old iMac encode it as H.264 or HEVC video. On a Late 2014 iMac 5K (iMac15,1, Haswell + R9 M290X), VideoToolbox measurements give these limits:

| codec | resolution | hardware decode on the iMac |
|---|---|---|
| H.264 | up to 4096×2304 | yes (143–229 fps) |
| H.264 | 5120×2880 | no |
| HEVC | any | no |

Apple Silicon also has no hardware H.264 encoder at 5120×2880. A video pipeline at native 5K therefore ends up as a software HEVC decode on the iMac's CPU. During testing, `VTDecoderXPCService` used about 120 % CPU, and the pointer and scrolling lagged.

## How

There is no video codec in this pipeline:

```
Apple Silicon Mac (sender)                                 old iMac (receiver, macOS 11+)
virtual 2560×1440 HiDPI display (CGVirtualDisplay)
 → ScreenCaptureKit, 5120×2880 BGRA
 → Metal compute: BC7 (mode 6) encode, ~0.85 ms/frame
 → only 64×64 tiles that changed vs. what the receiver has
 → LZ4 ── TCP over the Ethernet cable ──────────────►  LZ4 decode → replaceRegion into a BC7 texture
cursor position/image at 120 Hz (separate connection) ►  GPU samples BC7 natively, full-screen Metal
                                                          cursor drawn by the iMac's own hardware cursor
```

- **One frame in flight.** While the network is busy, frames are not queued. The next send diffs the latest encode against what the receiver already has.
- **The iMac decodes nothing.** BC7 is a GPU texture format, so the R9 M290X samples it directly. The decoded pixels are bit-identical to the Apple Silicon decode; each run verifies this with an RGB hash.
- **Tested on our setup:** M3 Ultra → iMac15,1 on macOS 11.7.11, gigabit Ethernet cable.
  - Image quality: PSNR ≈ 51 dB on real desktop screenshots.
  - Payload per frame: about 1.25 MB when scrolling one screen, about 0 for typing.
  - Idle CPU: receiver 0 %, sender ~1 %.
  - Latency for small changes: capture to iMac GPU-done is about 11 ms median, 29 ms p90.
  - Scrolling runs at 25–45 fps.
  - It is **not** meant for video playback.

## Status and limits

- Personal project, tested on exactly one pair of machines. Expect rough edges.
- The sender uses the **private** `CGVirtualDisplay` API (macOS 14+).
- Without a Developer ID the apps are ad-hoc signed. After each rebuild of the sender you must re-add it under *System Settings → Privacy & Security → Screen & System Audio Recording* with the "+" button. A background app gets no prompt.
- Wired only: the sender looks for the receiver via Bonjour and connects only on a wired interface.

## Build and install

```bash
./build.sh                      # sender (arm64, macOS 14+), receiver app (x86_64, macOS 11+), icon
# on the sender Mac
./scripts/install_sender.sh
# copy build/BCDReceiver.app, launchd/ and scripts/ to the iMac, then on the iMac
./scripts/install_receiver.sh
```

`phase0/` holds the feasibility benchmarks: the BC7 encoder on screenshots, and a BC7 texture probe for the receiver.

## Credits and references

- **[TargetBridge](https://github.com/swellweb/targetBridge)** by Marco Caciotti (MIT). The `CGVirtualDisplay` declarations in `Sender/Bridging.h` are copied from its bridging header (license reproduced in `LICENSE`). Its way of picking the HiDPI virtual display mode by backing pixels guided `VirtualDisplay.selectHiDPIMode`. This project started from trying TargetBridge on a 2014 iMac and measuring why it lagged there; the fix for its HEVC capability probe went upstream as a separate PR.
- **Chromium** `virtual_display_mac_util.mm`: TargetBridge verified its `CGVirtualDisplay` declarations against it.
- **[RetinaRelay](https://www.retinarelay.com/)** (commercial, closed source): the *idea* of sending GPU-compressed textures (it shows "BC7 mode 6") instead of video, and of drawing the pointer with the receiver's own cursor. Both come from its public product page and app UI. No code was used, and none is available.
- **BC7 / BPTC format**: encoder written from the Khronos Data Format Specification (BPTC) and Microsoft's BC7 format documentation (mode 6 bit layout, 4-bit index weights).
- Apple frameworks: ScreenCaptureKit, Metal, Network.framework, Compression (LZ4).
- Written with **Claude Code** (Anthropic). Earlier TargetBridge experiments on the same iMac were done with **OpenAI Codex**.

License: MIT (see `LICENSE`).

---

## 中文

让 **2014–2015 款 Retina 5K iMac** 当 Apple Silicon Mac 的原生 5K 扩展屏。这类 iMac 不支持目标显示器模式，也没有 HEVC 硬件解码。本项目免费，只要一根网线。

**原理**：发送端先在 GPU 上把虚拟屏画面编成 BC7 纹理，只传有变化的 64×64 区块，用 LZ4 压缩后经网线发给 iMac。iMac 的显卡能直接显示 BC7 纹理，CPU 完全不参与解码。鼠标走单独的连接，由 iMac 本机的硬件光标绘制。

**为什么不用视频**：实测 2014 款 iMac 只能硬解 4096×2304 以下的 H.264，HEVC 完全不能硬解；Apple Silicon 也编不了 5K 的 H.264。所以视频方案到了 5K，只能靠 iMac 的 CPU 软解，结果就是卡。

**实测**：M3 Ultra 搭配 iMac15,1（Big Sur），用千兆网线直连。

- **画质**：PSNR 约 51 dB，iMac 端解出的像素与发送端逐位一致。
- **CPU**：静止时接收端 0%。
- **延迟**：小改动从截屏到 iMac 显卡画完，中位数约 11 ms。
- **用途**：滚动每秒 25–45 帧，不适合看视频。

**参考与致谢**：

- **TargetBridge**（MIT）：借用了虚拟屏私有 API 的声明，参考了 HiDPI 模式的选取方法。
- **Chromium**：TargetBridge 那份 API 声明的原始出处。
- **RetinaRelay**（商业闭源）：借鉴了两个思路，「传 GPU 压缩纹理而不是视频」和「由接收端本机光标绘制鼠标」。没有用到它的任何代码。
- **BC7 规范**：编码器按 Khronos BPTC 规范和微软的 BC7 文档编写。
- **工具**：代码由 Claude Code 编写；早期在同一台 iMac 上试 TargetBridge 用的是 OpenAI Codex。
