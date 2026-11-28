// Vortex Crosshair - crosshair renderer
#include "crosshair.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace vx {

namespace {

constexpr float kPi = 3.14159265358979323846f;

// ---- constants recovered from the reference screenshot (tools/fit_reference.py) ----
// Soft "diamond" glow behind every blade: a rhombus centred on the blade whose
// half diagonals are proportional to the blade's, blurred with a gaussian.
constexpr float kGlowDiamondAlong  = 0.7033f;  // * (length / 2)
constexpr float kGlowDiamondAcross = 1.9569f;  // * (width / 2)
constexpr float kGlowDiamondShift  = 0.1362f;  // px, outward shift of the diamond centre
constexpr float kGlowSigma1 = 1.6218f;         // px
constexpr float kGlowAmp1   = 0.4147f;
// Tight glow hugging the actual blade + dot silhouette.
constexpr float kGlowSigma2 = 0.6783f;         // px
constexpr float kGlowAmp2   = 0.6737f;
// Centre dot halo: soft disc, linear falloff.
constexpr float kHaloRadius   = 2.2152f;       // * dot radius
constexpr float kHaloSoftness = 2.6196f;       // * dot radius
constexpr float kHaloAmp      = 0.3343f;
// Optional dark contrast shadow (not part of the reference look).
constexpr float kShadowSigma = 1.35f;
constexpr float kShadowAmp   = 1.6f;

inline float clamp01(float v) { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }

// Exact signed distance to a rhombus with half diagonals a (x) and b (y). (I. Quilez)
inline float sdRhombus(float px, float py, float a, float b) {
    px = std::fabs(px);
    py = std::fabs(py);
    const float bb = a * a + b * b;
    float h = ((a - 2.f * px) * a - (b - 2.f * py) * b) / bb;
    h = h < -1.f ? -1.f : (h > 1.f ? 1.f : h);
    const float dx = px - 0.5f * a * (1.f - h);
    const float dy = py - 0.5f * b * (1.f + h);
    const float d = std::sqrt(dx * dx + dy * dy);
    const float s = px * b + py * a - a * b;
    return s < 0.f ? -d : d;
}

// Area of the intersection between a convex quad (4 points, xy interleaved)
// and the rhombus |x|/a + |y|/b <= 1.
float clipArea(const float* quad, float a, float b) {
    float bufA[32], bufB[32];
    float* in = bufA;
    float* out = bufB;
    int n = 4;
    std::memcpy(in, quad, sizeof(float) * 8);
    const float ia = 1.f / a, ib = 1.f / b;
    static const float sx[4] = {1, -1, -1, 1};
    static const float sy[4] = {1, 1, -1, -1};
    for (int p = 0; p < 4 && n > 0; ++p) {
        const float nx = sx[p] * ia, ny = sy[p] * ib;
        int m = 0;
        for (int i = 0; i < n; ++i) {
            const float* P = in + 2 * i;
            const float* Q = in + 2 * ((i + 1) % n);
            const float fp = nx * P[0] + ny * P[1] - 1.f;
            const float fq = nx * Q[0] + ny * Q[1] - 1.f;
            if (fp <= 0.f) {
                out[2 * m] = P[0];
                out[2 * m + 1] = P[1];
                ++m;
            }
            if ((fp <= 0.f) != (fq <= 0.f)) {
                const float t = fp / (fp - fq);
                out[2 * m] = P[0] + (Q[0] - P[0]) * t;
                out[2 * m + 1] = P[1] + (Q[1] - P[1]) * t;
                ++m;
            }
        }
        std::swap(in, out);
        n = m;
    }
    if (n < 3) return 0.f;
    float area = 0.f;
    for (int i = 0; i < n; ++i) {
        const float* P = in + 2 * i;
        const float* Q = in + 2 * ((i + 1) % n);
        area += P[0] * Q[1] - Q[0] * P[1];
    }
    return std::fabs(area) * 0.5f;
}

// Coverage of the unit pixel square centred at blade-frame point (u, v) whose
// edges are given by the half-extent vectors e1 = (e1u, e1v), e2 = (e2u, e2v).
// pr = circumradius of the pixel square, invArea = 1 / pixel area (both in local units).
inline float pixelCoverage(float u, float v, float e1u, float e1v, float e2u, float e2v, float a,
                           float b, float invNorm, float pr, float invArea) {
    // conservative plane distance test against the pixel's circumscribed circle
    const float pd = (std::fabs(u) / a + std::fabs(v) / b - 1.f) * invNorm;
    if (pd >= pr) return 0.f;
    if (pd <= -pr) return 1.f;
    const float quad[8] = {u - e1u - e2u, v - e1v - e2v, u + e1u - e2u, v + e1v - e2v,
                           u + e1u + e2u, v + e1v + e2v, u - e1u + e2u, v - e1v + e2v};
    return clamp01(clipArea(quad, a, b) * invArea);
}

void gaussianBlur(std::vector<float>& img, int n, float sigma) {
    if (sigma <= 0.01f) return;
    const int r = std::max(1, (int)std::ceil(sigma * 3.5f));
    std::vector<float> k(2 * r + 1);
    float sum = 0;
    for (int i = -r; i <= r; ++i) {
        k[i + r] = std::exp(-(float)(i * i) / (2.f * sigma * sigma));
        sum += k[i + r];
    }
    for (float& v : k) v /= sum;
    std::vector<float> tmp(img.size(), 0.f);
    for (int y = 0; y < n; ++y) {
        const float* row = &img[(size_t)y * n];
        float* o = &tmp[(size_t)y * n];
        for (int x = 0; x < n; ++x) {
            float acc = 0;
            const int i0 = std::max(-r, -x), i1 = std::min(r, n - 1 - x);
            for (int i = i0; i <= i1; ++i) acc += row[x + i] * k[i + r];
            o[x] = acc;
        }
    }
    for (int y = 0; y < n; ++y) {
        float* o = &img[(size_t)y * n];
        const int i0 = std::max(-r, -y), i1 = std::min(r, n - 1 - y);
        for (int x = 0; x < n; ++x) {
            float acc = 0;
            for (int i = i0; i <= i1; ++i) acc += tmp[(size_t)(y + i) * n + x] * k[i + r];
            o[x] = acc;
        }
    }
}

}  // namespace

void CrosshairRenderer::prepare(const CrosshairStyle& s) {
    const float key[14] = {(float)s.blades, s.length, s.width, s.gap, s.outline, s.dot, s.scale,
                           s.glow, s.glowSize, s.halo, s.shadow, s.showOutline ? 1.f : 0.f, 0, 0};
    if (valid_ && std::memcmp(key, key_, sizeof(key)) == 0) return;
    std::memcpy(key_, key, sizeof(key));
    valid_ = true;

    const float S = std::max(0.05f, s.scale);
    Geo g{};
    g.blades = std::max(1, std::min(12, s.blades));
    g.a = std::max(0.25f, s.length * 0.5f * S);
    g.b = std::max(0.25f, s.width * 0.5f * S);
    g.m = std::max(0.f, s.gap * S) + g.a;
    g.dot = std::max(0.f, s.dot * S);
    g.outline = s.showOutline && s.outline > 0.01f;
    if (g.outline) {
        const float inr = g.a * g.b / std::sqrt(g.a * g.a + g.b * g.b);  // centre-to-edge distance
        const float k = std::max(0.f, 1.f - (s.outline * S) / inr);
        g.ai = g.a * k;
        g.bi = g.b * k;
    } else {
        g.ai = g.a;
        g.bi = g.b;
    }
    geo_ = g;

    const float gs = std::max(0.1f, s.glowSize);
    const float sig1 = kGlowSigma1 * S * gs, sig2 = kGlowSigma2 * S * gs;
    const float ga = kGlowDiamondAlong * g.a, gb = kGlowDiamondAcross * g.b;
    const float gm = g.m + kGlowDiamondShift * S;
    const float haloR = kHaloRadius * g.dot, haloS = std::max(0.05f, kHaloSoftness * g.dot);

    hasGlow_ = s.glow > 0.001f || (s.halo > 0.001f && g.dot > 0.f);
    hasShadow_ = s.shadow > 0.001f;

    float reach = g.m + g.a;
    float glowReach = std::max(gm + ga + 3.5f * sig1, g.m + g.a + 3.5f * sig2);
    if (hasGlow_) reach = std::max(reach, glowReach);
    if (g.dot > 0) reach = std::max(reach, haloR + haloS * 0.5f);
    if (hasShadow_) reach = std::max(reach, g.m + g.a + 3.5f * kShadowSigma * S);
    extent_ = reach + 2.f;

    glowField_.clear();
    shadowField_.clear();
    if (!hasGlow_ && !hasShadow_) {
        fieldN_ = 0;
        return;
    }
    fieldStep_ = 0.5f;
    fieldN_ = (int)std::ceil(2.f * extent_ / fieldStep_) + 3;
    fieldOrigin_ = -0.5f * (fieldN_ - 1) * fieldStep_;
    const int N = fieldN_;
    std::vector<float> srcDiamond((size_t)N * N), srcShape((size_t)N * N);
    const float step = 2.f * kPi / g.blades;
    for (int j = 0; j < N; ++j) {
        const float y = fieldOrigin_ + j * fieldStep_;
        for (int i = 0; i < N; ++i) {
            const float x = fieldOrigin_ + i * fieldStep_;
            float dBlade = 1e9f, dDiamond = 1e9f;
            for (int k = 0; k < g.blades; ++k) {
                const float ang = k * step;
                const float ux = std::sin(ang), uy = -std::cos(ang);
                const float u = x * ux + y * uy, v = x * (-uy) + y * ux;
                dBlade = std::min(dBlade, sdRhombus(u - g.m, v, g.a, g.b));
                dDiamond = std::min(dDiamond, sdRhombus(u - gm, v, ga, gb));
            }
            const float r = std::sqrt(x * x + y * y);
            const float covDot = g.dot > 0 ? clamp01(0.5f - (r - g.dot)) : 0.f;
            srcDiamond[(size_t)j * N + i] = std::max(clamp01(0.5f - dDiamond), covDot);
            srcShape[(size_t)j * N + i] = std::max(clamp01(0.5f - dBlade), covDot);
        }
    }
    if (hasShadow_) {
        shadowField_ = srcShape;
        gaussianBlur(shadowField_, N, kShadowSigma * S / fieldStep_);
        const float amp = kShadowAmp * s.shadow;
        for (float& v : shadowField_) v = clamp01(v * amp);
    }
    if (hasGlow_) {
        std::vector<float> g1 = srcDiamond, g2 = srcShape;
        gaussianBlur(g1, N, sig1 / fieldStep_);
        gaussianBlur(g2, N, sig2 / fieldStep_);
        const float a1 = kGlowAmp1 * s.glow, a2 = kGlowAmp2 * s.glow;
        const float ah = clamp01(kHaloAmp * s.halo);
        glowField_.assign((size_t)N * N, 0.f);
        for (int j = 0; j < N; ++j) {
            const float y = fieldOrigin_ + j * fieldStep_;
            for (int i = 0; i < N; ++i) {
                const float x = fieldOrigin_ + i * fieldStep_;
                const size_t id = (size_t)j * N + i;
                const float v1 = clamp01(a1 * g1[id]);
                const float v2 = clamp01(a2 * g2[id]);
                float halo = 0.f;
                if (g.dot > 0.f && ah > 0.f) {
                    const float r = std::sqrt(x * x + y * y);
                    halo = ah * clamp01(0.5f - (r - haloR) / haloS);
                }
                glowField_[id] = 1.f - (1.f - v1) * (1.f - v2) * (1.f - halo);
            }
        }
    }
}

float CrosshairRenderer::sampleField(const std::vector<float>& f, float x, float y) const {
    const float gx = (x - fieldOrigin_) / fieldStep_;
    const float gy = (y - fieldOrigin_) / fieldStep_;
    if (gx < 0.f || gy < 0.f) return 0.f;
    const int ix = (int)gx, iy = (int)gy;
    if (ix >= fieldN_ - 1 || iy >= fieldN_ - 1) return 0.f;
    const float fx = gx - ix, fy = gy - iy;
    const float* p = &f[(size_t)iy * fieldN_ + ix];
    const float top = p[0] + (p[1] - p[0]) * fx;
    const float bot = p[fieldN_] + (p[fieldN_ + 1] - p[fieldN_]) * fx;
    return top + (bot - top) * fy;
}

void CrosshairRenderer::render(uint32_t* px, int w, int h, int stridePx, float cx, float cy,
                               float angle, const CrosshairStyle& s, int clipX0, int clipY0,
                               int clipX1, int clipY1, float zoom) const {
    const Geo& g = geo_;
    if (!(zoom > 0.01f)) zoom = 1.f;
    const float iz = 1.f / zoom;
    const float pr = 0.7072f * iz, invArea = zoom * zoom;
    const float E = extent_ * zoom;  // in buffer pixels
    const float El = extent_;        // in local units
    int x0 = std::max({0, clipX0, (int)std::floor(cx - E)});
    int y0 = std::max({0, clipY0, (int)std::floor(cy - E)});
    int x1 = std::min({w, clipX1, (int)std::ceil(cx + E) + 1});
    int y1 = std::min({h, clipY1, (int)std::ceil(cy + E) + 1});
    if (x0 >= x1 || y0 >= y1) return;

    const float ca = std::cos(angle), sa = std::sin(angle);
    const int nb = g.blades;
    const float step = 2.f * kPi / nb;
    float bux[12], buy[12];
    for (int k = 0; k < nb; ++k) {
        const float ang = angle + k * step;
        bux[k] = std::sin(ang);
        buy[k] = -std::cos(ang);
    }
    const float invNormO = 1.f / std::sqrt(1.f / (g.a * g.a) + 1.f / (g.b * g.b));
    const float invNormI = (g.ai > 0.01f && g.bi > 0.01f)
                               ? 1.f / std::sqrt(1.f / (g.ai * g.ai) + 1.f / (g.bi * g.bi))
                               : 0.f;
    const bool hasInner = invNormI > 0.f;
    const float outerR = g.m + g.a + 1.f * iz, innerR = std::max(0.f, g.m - g.a - 1.f * iz);

    const float op = clamp01(s.opacity);
    const RGBA fill = s.fill, line = s.line, dotc = s.dotCol, glowc = s.glowCol;

    for (int y = y0; y < y1; ++y) {
        uint32_t* row = px + (size_t)y * stridePx;
        const float dy = (y + 0.5f - cy) * iz;
        for (int x = x0; x < x1; ++x) {
            const float dx = (x + 0.5f - cx) * iz;
            const float r2 = dx * dx + dy * dy;
            if (r2 > El * El) continue;
            float R = 0, G = 0, B = 0, A = 0;
            auto over = [&](const RGBA& c, float a) {
                if (a <= 0.f) return;
                const float ia = 1.f - a;
                R = c.r * a + R * ia;
                G = c.g * a + G * ia;
                B = c.b * a + B * ia;
                A = a + A * ia;
            };
            // rotated sample position in master space
            const float mx = ca * dx + sa * dy, my = -sa * dx + ca * dy;
            if (hasShadow_) {
                const float sv = sampleField(shadowField_, mx, my);
                if (sv > 0.f) over(RGBA{0, 0, 0, 1}, sv);
            }
            if (hasGlow_) {
                const float gv = sampleField(glowField_, mx, my);
                if (gv > 0.f) over(glowc, gv * glowc.a);
            }
            // crisp blades
            const float r = std::sqrt(r2);
            if (r <= outerR && r >= innerR) {
                float covO = 0.f, covI = 0.f;
                for (int k = 0; k < nb; ++k) {
                    const float ux = bux[k], uy = buy[k];
                    const float vx = -uy, vy = ux;
                    const float u = dx * ux + dy * uy - g.m;
                    const float v = dx * vx + dy * vy;
                    if (std::fabs(u) > g.a + pr || std::fabs(v) > g.b + pr) continue;
                    // half-extent vectors of the pixel square in the blade frame
                    const float e1u = 0.5f * iz * ux, e1v = 0.5f * iz * vx;  // screen x axis
                    const float e2u = 0.5f * iz * uy, e2v = 0.5f * iz * vy;  // screen y axis
                    covO = std::max(covO, pixelCoverage(u, v, e1u, e1v, e2u, e2v, g.a, g.b, invNormO, pr, invArea));
                    if (hasInner && g.outline)
                        covI = std::max(covI, pixelCoverage(u, v, e1u, e1v, e2u, e2v, g.ai, g.bi, invNormI, pr, invArea));
                }
                if (g.outline) {
                    over(line, covO * line.a);
                    over(fill, covI * fill.a);
                } else {
                    over(fill, covO * fill.a);
                }
            }
            if (g.dot > 0.f) {
                const float cd = clamp01(0.5f - (r - g.dot) * zoom);
                if (cd > 0.f) over(dotc, cd * dotc.a);
            }
            if (A <= 0.f) continue;
            R *= op; G *= op; B *= op; A *= op;
            // blend premultiplied onto destination (BGRA8 premultiplied)
            uint32_t d = row[x];
            const float ia = 1.f - A;
            const float db = (float)(d & 255), dg = (float)((d >> 8) & 255),
                        dr = (float)((d >> 16) & 255), da = (float)(d >> 24);
            const int ob = (int)(B * 255.f + db * ia + 0.5f);
            const int og = (int)(G * 255.f + dg * ia + 0.5f);
            const int orr = (int)(R * 255.f + dr * ia + 0.5f);
            const int oa = (int)(A * 255.f + da * ia + 0.5f);
            row[x] = (uint32_t)std::min(ob, 255) | ((uint32_t)std::min(og, 255) << 8) |
                     ((uint32_t)std::min(orr, 255) << 16) | ((uint32_t)std::min(oa, 255) << 24);
        }
    }
}

}  // namespace vx
