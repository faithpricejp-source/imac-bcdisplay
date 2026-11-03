# Phase 0 实测（2026-11-03）

输入：两张真实 5K 截图（iMac 虚拟屏 = 中文网页暗色，Mac Studio 主屏）。编码器 `BCKernels.metal.txt`（BC7 mode 6 单子集 PCA 端点 / BC1），64×64 tile 级差分，Apple Compression LZ4。

## Mac Studio（M3 Ultra）编码端

| 指标 | BC7 mode 6 | BC1 |
|---|---|---|
| 5K 整帧 GPU 编码 | 0.85 ms | 0.13 ms |
| 画质 PSNR（两张图） | 51.0 / 49.2 dB | 41.7 / 39.1 dB |
| 整帧 LZ4 后（暗色网页 / 主屏） | 1.05 / 3.47 MB | 0.54 / 1.63 MB |
| 滚动 240px（2191/3600 tile 变化） | 1.25 MB | 0.62 MB |
| 打一行字（600×40 区域） | 20 tile，≈0 MB | 同 |
| LZ4 压缩耗时（整帧） | 3.8–5.4 ms | 1.7–2.9 ms |

千兆网约 110 MB/s：BC7 整帧最坏 31.5 ms，滚动 11.4 ms。LZFSE 小 25% 但慢 10 倍，不用。
裁图目检（`out/crop*_src.png` vs `out/crop*_BC7m6.png`）：中文正文、细边框看不出差别。

## iMac（R9 M290X，Big Sur 11.7.11）接收端

| 指标 | BC7 | BC1 |
|---|---|---|
| 建 BC 纹理 | 成功 | 成功 |
| LZ4 解压整帧 | 3.5 ms | 2.2 ms |
| 整帧上传 replaceRegion | 5.0 ms | 3.1 ms |
| 单 tile 上传 | 1.1 µs | 0.6 µs |
| 解码结果 RGB 哈希 | `ed35873c679dd59b`，与 M3 Ultra 逐位一致 | `aabfd1ba253f18bf`，一致 |

测时 iMac 上 TargetBridge 软解占着 ~120% CPU，数字偏保守。

## 结论
走得通，且远好于事前估算（满屏滚动 15–25 帧）：BC7 原生 5K，滚动一屏的网络耗时约 11 ms，最坏整帧换页约 31 ms。不需要 BC1 降档，静态清晰优先的需求下一律 BC7。
