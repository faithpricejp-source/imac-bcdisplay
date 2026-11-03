#include <metal_stdlib>
using namespace metal;

// ---------- shared helpers ----------
constant ushort kW4[16] = {0,4,9,13,17,21,26,30,34,38,43,47,51,55,60,64};

struct BitWriter {
    uint w[4];
    uint pos;
};

inline void bw_put(thread BitWriter &b, uint value, uint nbits) {
    for (uint i = 0; i < nbits; ++i) {
        uint bit = (value >> i) & 1u;
        uint p = b.pos + i;
        b.w[p >> 5] |= bit << (p & 31u);
    }
    b.pos += nbits;
}

inline void load_block(texture2d<float, access::read> src, uint2 bxy, thread float4 px[16]) {
    uint2 base = bxy * 4;
    uint W = src.get_width(), H = src.get_height();
    for (uint y = 0; y < 4; ++y)
        for (uint x = 0; x < 4; ++x) {
            uint2 p = min(base + uint2(x, y), uint2(W - 1, H - 1));
            px[y * 4 + x] = src.read(p) * 255.0;
        }
}

// principal axis endpoints (RGB), alpha handled separately
inline void pca_endpoints(thread float4 px[16], thread float3 &lo, thread float3 &hi) {
    float3 mean = 0;
    for (int i = 0; i < 16; ++i) mean += px[i].rgb;
    mean /= 16.0;
    float3x3 cov = float3x3(0);
    for (int i = 0; i < 16; ++i) {
        float3 d = px[i].rgb - mean;
        cov[0] += d.x * d; cov[1] += d.y * d; cov[2] += d.z * d;
    }
    // initial axis: max-min diagonal
    float3 mn = px[0].rgb, mx = px[0].rgb;
    for (int i = 1; i < 16; ++i) { mn = min(mn, px[i].rgb); mx = max(mx, px[i].rgb); }
    float3 axis = mx - mn;
    if (dot(axis, axis) < 1e-6) { lo = mean; hi = mean; return; }
    for (int it = 0; it < 4; ++it) {
        float3 n = cov * axis;
        float l = length(n);
        if (l < 1e-6) break;
        axis = n / l;
    }
    axis = normalize(axis);
    float tmin = 1e9, tmax = -1e9;
    for (int i = 0; i < 16; ++i) {
        float t = dot(px[i].rgb - mean, axis);
        tmin = min(tmin, t); tmax = max(tmax, t);
    }
    lo = clamp(mean + axis * tmin, 0.0, 255.0);
    hi = clamp(mean + axis * tmax, 0.0, 255.0);
}

// ---------- BC7 mode 6 ----------
// endpoints: 7 bits per channel + 1 p-bit per endpoint (shared across RGBA)
inline uint4 q7p(float4 v, thread uint &pbit) {
    float best = 1e30; uint4 bq = 0; uint bp = 0;
    for (uint p = 0; p < 2; ++p) {
        uint4 q = uint4(clamp(round((v - float(p)) / 2.0), 0.0, 127.0));
        float4 r = float4((q << 1) | p);
        float e = dot(r - v, r - v);
        if (e < best) { best = e; bq = q; bp = p; }
    }
    pbit = bp;
    return bq;
}

kernel void bc7_mode6(texture2d<float, access::read> src [[texture(0)]],
                      device uint4 *out [[buffer(0)]],
                      constant uint &blocksW [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint blocksH = (src.get_height() + 3) / 4;
    if (gid.x >= blocksW || gid.y >= blocksH) return;
    float4 px[16];
    load_block(src, gid, px);
    float3 lo, hi;
    pca_endpoints(px, lo, hi);
    float amin = 255, amax = 0;
    for (int i = 0; i < 16; ++i) { amin = min(amin, px[i].a); amax = max(amax, px[i].a); }

    uint p0, p1;
    uint4 e0q = q7p(float4(lo, amin), p0);
    uint4 e1q = q7p(float4(hi, amax), p1);
    float4 e0 = float4((e0q << 1) | p0);
    float4 e1 = float4((e1q << 1) | p1);

    // palette
    float4 pal[16];
    for (int k = 0; k < 16; ++k) {
        float w = float(kW4[k]);
        pal[k] = floor(((64.0 - w) * e0 + w * e1 + 32.0) / 64.0);
    }
    uint idx[16];
    for (int i = 0; i < 16; ++i) {
        float best = 1e30; uint bi = 0;
        for (uint k = 0; k < 16; ++k) {
            float4 d = pal[k] - px[i];
            float e = dot(d, d);
            if (e < best) { best = e; bi = k; }
        }
        idx[i] = bi;
    }
    // anchor fix: index 0 must have MSB clear
    if (idx[0] & 8u) {
        uint4 tq = e0q; e0q = e1q; e1q = tq;
        uint tp = p0; p0 = p1; p1 = tp;
        for (int i = 0; i < 16; ++i) idx[i] = 15u - idx[i];
    }
    BitWriter b; b.w[0] = b.w[1] = b.w[2] = b.w[3] = 0; b.pos = 0;
    bw_put(b, 1u << 6, 7);                 // mode 6
    bw_put(b, e0q.x, 7); bw_put(b, e1q.x, 7);
    bw_put(b, e0q.y, 7); bw_put(b, e1q.y, 7);
    bw_put(b, e0q.z, 7); bw_put(b, e1q.z, 7);
    bw_put(b, e0q.w, 7); bw_put(b, e1q.w, 7);
    bw_put(b, p0, 1); bw_put(b, p1, 1);
    bw_put(b, idx[0], 3);
    for (int i = 1; i < 16; ++i) bw_put(b, idx[i], 4);
    out[gid.y * blocksW + gid.x] = uint4(b.w[0], b.w[1], b.w[2], b.w[3]);
}

// ---------- BC1 ----------
inline uint to565(float3 c) {
    uint r = uint(clamp(round(c.r * 31.0 / 255.0), 0.0, 31.0));
    uint g = uint(clamp(round(c.g * 63.0 / 255.0), 0.0, 63.0));
    uint b = uint(clamp(round(c.b * 31.0 / 255.0), 0.0, 31.0));
    return (r << 11) | (g << 5) | b;
}
inline float3 from565(uint v) {
    uint r = (v >> 11) & 31u, g = (v >> 5) & 63u, b = v & 31u;
    return float3((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
}

kernel void bc1(texture2d<float, access::read> src [[texture(0)]],
                device uint2 *out [[buffer(0)]],
                constant uint &blocksW [[buffer(1)]],
                uint2 gid [[thread_position_in_grid]]) {
    uint blocksH = (src.get_height() + 3) / 4;
    if (gid.x >= blocksW || gid.y >= blocksH) return;
    float4 px[16];
    load_block(src, gid, px);
    float3 lo, hi;
    pca_endpoints(px, lo, hi);
    uint c0 = to565(hi), c1 = to565(lo);
    if (c0 < c1) { uint t = c0; c0 = c1; c1 = t; }
    uint bits = 0;
    if (c0 == c1) {
        bits = 0; // all index 0
    } else {
        float3 a = from565(c0), b = from565(c1);
        float3 pal[4] = { a, b, (2.0 * a + b) / 3.0, (a + 2.0 * b) / 3.0 };
        for (int i = 0; i < 16; ++i) {
            float best = 1e30; uint bi = 0;
            for (uint k = 0; k < 4; ++k) {
                float3 d = pal[k] - px[i].rgb;
                float e = dot(d, d);
                if (e < best) { best = e; bi = k; }
            }
            bits |= bi << (2 * i);
        }
    }
    out[gid.y * blocksW + gid.x] = uint2(c0 | (c1 << 16), bits);
}

// ---------- decode check: sample a compressed texture back to RGBA8 ----------
kernel void readback(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(src.read(gid), gid);
}
