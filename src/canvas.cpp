// Vortex Crosshair - software 2D renderer implementation
#include "canvas.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#if defined(__SSE2__) || defined(_M_X64)
#include <emmintrin.h>
#define VX_SSE2 1
#endif

#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wsign-compare"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif
#include "../third_party/stb_truetype.h"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#include "font_data.h"

namespace vx {

namespace {
inline float clamp01(float v) { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }
inline float sq(float v) { return v * v; }

// erf approximation (Abramowitz & Stegun 7.1.26), |error| < 1.5e-7
inline float erfApprox(float x) {
    const float s = x < 0 ? -1.f : 1.f;
    x = std::fabs(x);
    const float t = 1.f / (1.f + 0.3275911f * x);
    const float y = 1.f - (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t - 0.284496736f) * t +
                           0.254829592f) * t * std::exp(-x * x);
    return s * y;
}
}  // namespace

RGBA hexc(uint32_t rgb, float a) {
    return RGBA{((rgb >> 16) & 255) / 255.f, ((rgb >> 8) & 255) / 255.f, (rgb & 255) / 255.f, a};
}


void Canvas::attach(uint32_t* p, int width, int height, int strideInPixels) {
    px = p;
    w = width;
    h = height;
    stride = strideInPixels;
    resetClip();
}

void Canvas::setClip(int x0, int y0, int x1, int y1) {
    clipX0 = std::max(0, x0);
    clipY0 = std::max(0, y0);
    clipX1 = std::min(w, x1);
    clipY1 = std::min(h, y1);
    if (clipX1 < clipX0) clipX1 = clipX0;
    if (clipY1 < clipY0) clipY1 = clipY0;
}

void Canvas::setClip(const Rc& r) {
    setClip((int)std::floor(r.x), (int)std::floor(r.y), (int)std::ceil(r.r()), (int)std::ceil(r.b()));
}

void Canvas::pushClip(const Rc& r) {
    clipStack.insert(clipStack.end(), {clipX0, clipY0, clipX1, clipY1});
    const int x0 = std::max(clipX0, (int)std::floor(r.x)), y0 = std::max(clipY0, (int)std::floor(r.y));
    const int x1 = std::min(clipX1, (int)std::ceil(r.r())), y1 = std::min(clipY1, (int)std::ceil(r.b()));
    clipX0 = x0;
    clipY0 = y0;
    clipX1 = std::max(x0, x1);
    clipY1 = std::max(y0, y1);
}

void Canvas::popClip() {
    if (clipStack.size() < 4) return;
    clipY1 = clipStack.back(); clipStack.pop_back();
    clipX1 = clipStack.back(); clipStack.pop_back();
    clipY0 = clipStack.back(); clipStack.pop_back();
    clipX0 = clipStack.back(); clipStack.pop_back();
}

void Canvas::resetClip() {
    clipX0 = clipY0 = 0;
    clipX1 = w;
    clipY1 = h;
}

void Canvas::clear(uint32_t v) { clearRect(0, 0, w, h, v); }

void Canvas::clearRect(int x0, int y0, int x1, int y1, uint32_t v) {
    x0 = std::max(x0, clipX0);
    y0 = std::max(y0, clipY0);
    x1 = std::min(x1, clipX1);
    y1 = std::min(y1, clipY1);
    for (int y = y0; y < y1; ++y) std::fill(px + (size_t)y * stride + x0, px + (size_t)y * stride + x1, v);
}

namespace {
// Integer "over" of one premultiplied pixel.
inline uint32_t overPixel(uint32_t dv, uint32_t sp) {
    const uint32_t sa = sp >> 24;
    if (sa == 255) return sp;
    const uint32_t ia = 255 - sa;
    uint32_t rb = (dv & 0x00FF00FFu) * ia + 0x00800080u;
    rb = ((rb + ((rb >> 8) & 0x00FF00FFu)) >> 8) & 0x00FF00FFu;
    uint32_t ag = ((dv >> 8) & 0x00FF00FFu) * ia + 0x00800080u;
    ag = (ag + ((ag >> 8) & 0x00FF00FFu)) & 0xFF00FF00u;
    const uint32_t dd = rb | ag;
    uint32_t c0 = (sp & 255) + (dd & 255), c1 = ((sp >> 8) & 255) + ((dd >> 8) & 255);
    uint32_t c2 = ((sp >> 16) & 255) + ((dd >> 16) & 255), c3 = (sp >> 24) + (dd >> 24);
    c0 = c0 > 255 ? 255 : c0;
    c1 = c1 > 255 ? 255 : c1;
    c2 = c2 > 255 ? 255 : c2;
    c3 = c3 > 255 ? 255 : c3;
    return c0 | (c1 << 8) | (c2 << 16) | (c3 << 24);
}

// Fast integer "over" for a run of fully covered pixels (constant colour).
inline void blendRun(uint32_t* p, int n, float r, float g, float b, float a) {
    const uint32_t sa = (uint32_t)(a * 255.f + 0.5f);
    if (sa == 0 || n <= 0) return;
    const uint32_t sr = (uint32_t)(r * 255.f + 0.5f), sg = (uint32_t)(g * 255.f + 0.5f),
                   sb = (uint32_t)(b * 255.f + 0.5f);
    const uint32_t src = std::min(sb, sa) | (std::min(sg, sa) << 8) | (std::min(sr, sa) << 16) | (sa << 24);
    if (sa >= 255) {
        std::fill(p, p + n, src);
        return;
    }
    int i = 0;
#ifdef VX_SSE2
    const __m128i zero = _mm_setzero_si128();
    const __m128i vsrc = _mm_unpacklo_epi8(_mm_set1_epi32((int)src), zero);
    const __m128i via = _mm_set1_epi16((short)(255 - sa));
    const __m128i r128 = _mm_set1_epi16(128);
    for (; i + 4 <= n; i += 4) {
        const __m128i d = _mm_loadu_si128((const __m128i*)(p + i));
        __m128i lo = _mm_add_epi16(_mm_mullo_epi16(_mm_unpacklo_epi8(d, zero), via), r128);
        __m128i hi = _mm_add_epi16(_mm_mullo_epi16(_mm_unpackhi_epi8(d, zero), via), r128);
        lo = _mm_srli_epi16(_mm_add_epi16(lo, _mm_srli_epi16(lo, 8)), 8);
        hi = _mm_srli_epi16(_mm_add_epi16(hi, _mm_srli_epi16(hi, 8)), 8);
        _mm_storeu_si128((__m128i*)(p + i), _mm_packus_epi16(_mm_add_epi16(lo, vsrc), _mm_add_epi16(hi, vsrc)));
    }
#endif
    for (; i < n; ++i) p[i] = overPixel(p[i], src);
}

struct SolidPaint {
    float r, g, b, a;  // premultiplied
    void at(int, int, float& R, float& G, float& B, float& A) const { R = r; G = g; B = b; A = a; }
    bool rowConst() const { return true; }
};

struct GradPaint {
    RGBA c0, c1;
    float o, len;  // start coordinate and length along axis
    bool vertical;
    void at(int x, int y, float& R, float& G, float& B, float& A) const {
        const float t = clamp01(((vertical ? y : x) + 0.5f - o) / len);
        const float a = c0.a + (c1.a - c0.a) * t;
        R = (c0.r + (c1.r - c0.r) * t) * a;
        G = (c0.g + (c1.g - c0.g) * t) * a;
        B = (c0.b + (c1.b - c0.b) * t) * a;
        A = a;
    }
    bool rowConst() const { return vertical; }
};

template <class P>
void rasterRoundRect(Canvas& cv, const Rc& r, float radius, const P& paint) {
    if (r.w <= 0.f || r.h <= 0.f) return;
    int x0 = std::max(cv.clipX0, (int)std::floor(r.x)), y0 = std::max(cv.clipY0, (int)std::floor(r.y));
    int x1 = std::min(cv.clipX1, (int)std::ceil(r.r())), y1 = std::min(cv.clipY1, (int)std::ceil(r.b()));
    if (x0 >= x1 || y0 >= y1) return;
    const float hw = r.w * 0.5f, hh = r.h * 0.5f, cx = r.cx(), cy = r.cy();
    const float rad = std::max(0.f, std::min({radius, hw, hh}));
    const float ga = cv.globalAlpha;
    for (int y = y0; y < y1; ++y) {
        const float py = y + 0.5f;
        // fully covered span on this row
        int xs = x1, xe = x0 - 1;
        const float qy = std::fabs(py - cy) - (hh - rad);
        if (qy <= rad - 0.5f) {
            float qxMax;
            if (qy <= 0.f)
                qxMax = rad - 0.5f;
            else
                qxMax = std::sqrt(std::max(0.f, sq(rad - 0.5f) - sq(qy)));
            const float half = hw - rad + qxMax;
            if (half > 0.f) {
                xs = std::max(x0, (int)std::ceil(cx - half - 0.5f));
                xe = std::min(x1 - 1, (int)std::floor(cx + half - 0.5f));
            }
        }
        uint32_t* row = cv.px + (size_t)y * cv.stride;
        const bool rc = paint.rowConst();
        float RR = 0, GG = 0, BB = 0, AA = 0;
        if (rc) paint.at(x0, y, RR, GG, BB, AA);
        auto edge = [&](int x) {
            const float d = sdRoundRect(x + 0.5f, py, cx, cy, hw, hh, rad);
            const float cov = clamp01(0.5f - d) * ga;
            if (cov <= 0.f) return;
            float R = RR, G = GG, B = BB, A = AA;
            if (!rc) paint.at(x, y, R, G, B, A);
            cv.blend(x, y, R * cov, G * cov, B * cov, A * cov);
        };
        if (xs > xe) {
            for (int x = x0; x < x1; ++x) edge(x);
            continue;
        }
        for (int x = x0; x < xs; ++x) edge(x);
        if (rc) {
            blendRun(row + xs, xe - xs + 1, RR * ga, GG * ga, BB * ga, AA * ga);
        } else {
            for (int x = xs; x <= xe; ++x) {
                float R, G, B, A;
                paint.at(x, y, R, G, B, A);
                cv.blend(x, y, R * ga, G * ga, B * ga, A * ga);
            }
        }
        for (int x = xe + 1; x < x1; ++x) edge(x);
    }
}
}  // namespace

void Canvas::fillRect(const Rc& r, const RGBA& c) { fillRoundRect(r, 0.f, c); }

void Canvas::fillRoundRect(const Rc& r, float radius, const RGBA& c) {
    if (c.a <= 0.f) return;
    rasterRoundRect(*this, r, radius, SolidPaint{c.r * c.a, c.g * c.a, c.b * c.a, c.a});
}

void Canvas::fillRoundRectGrad(const Rc& r, float radius, const RGBA& c0, const RGBA& c1, bool vertical) {
    GradPaint p{c0, c1, vertical ? r.y : r.x, std::max(1e-3f, vertical ? r.h : r.w), vertical};
    rasterRoundRect(*this, r, radius, p);
}

void Canvas::strokeRoundRect(const Rc& r, float radius, float width, const RGBA& c) {
    strokeRoundRectGrad(r, radius, width, c, c);
}

void Canvas::strokeRoundRectGrad(const Rc& r, float radius, float width, const RGBA& top, const RGBA& bottom) {
    if (r.w <= 0 || r.h <= 0 || width <= 0) return;
    int x0 = std::max(clipX0, (int)std::floor(r.x)), y0 = std::max(clipY0, (int)std::floor(r.y));
    int x1 = std::min(clipX1, (int)std::ceil(r.r())), y1 = std::min(clipY1, (int)std::ceil(r.b()));
    const float hw = r.w * 0.5f, hh = r.h * 0.5f, cx = r.cx(), cy = r.cy();
    const float rad = std::max(0.f, std::min({radius, hw, hh}));
    const float iw = hw - width, ih = hh - width, irad = std::max(0.f, rad - width);
    for (int y = y0; y < y1; ++y) {
        const float py = y + 0.5f;
        const float t = clamp01((py - r.y) / r.h);
        const RGBA c = mix(top, bottom, t);
        // inner region where the ring has no coverage: skip it quickly
        int ss = x1, se = x0 - 1;
        if (iw > 1.f && ih > 1.f) {
            const float qy = std::fabs(py - cy) - (ih - irad);
            if (qy <= irad - 0.5f) {
                const float qxMax = qy <= 0.f ? irad - 0.5f : std::sqrt(std::max(0.f, sq(irad - 0.5f) - sq(qy)));
                const float half = iw - irad + qxMax;
                if (half > 0.f) {
                    ss = (int)std::ceil(cx - half - 0.5f);
                    se = (int)std::floor(cx + half - 0.5f);
                }
            }
        }
        for (int x = x0; x < x1; ++x) {
            if (x >= ss && x <= se) {
                x = se;
                continue;
            }
            const float pxc = x + 0.5f;
            const float dO = sdRoundRect(pxc, py, cx, cy, hw, hh, rad);
            const float covO = clamp01(0.5f - dO);
            if (covO <= 0.f) continue;
            float covI = 0.f;
            if (iw > 0.f && ih > 0.f) covI = clamp01(0.5f - sdRoundRect(pxc, py, cx, cy, iw, ih, irad));
            const float cov = std::max(0.f, covO - covI) * c.a * globalAlpha;
            if (cov <= 0.f) continue;
            blend(x, y, c.r * cov, c.g * cov, c.b * cov, cov);
        }
    }
}

void Canvas::fillCircle(float x, float y, float radius, const RGBA& c) {
    fillRoundRect(Rc{x - radius, y - radius, radius * 2, radius * 2}, radius, c);
}

void Canvas::strokeCircle(float x, float y, float radius, float width, const RGBA& c) {
    const float ro = radius + width * 0.5f;
    strokeRoundRect(Rc{x - ro, y - ro, ro * 2, ro * 2}, ro, width, c);
}

void Canvas::line(float ax, float ay, float bx, float by, float width, const RGBA& c) {
    const float hw = width * 0.5f;
    int x0 = std::max(clipX0, (int)std::floor(std::min(ax, bx) - hw - 1));
    int y0 = std::max(clipY0, (int)std::floor(std::min(ay, by) - hw - 1));
    int x1 = std::min(clipX1, (int)std::ceil(std::max(ax, bx) + hw + 1));
    int y1 = std::min(clipY1, (int)std::ceil(std::max(ay, by) + hw + 1));
    const float dx = bx - ax, dy = by - ay;
    const float ll = dx * dx + dy * dy;
    const float A = c.a * globalAlpha;
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) {
            const float px_ = x + 0.5f - ax, py_ = y + 0.5f - ay;
            float t = ll > 0 ? (px_ * dx + py_ * dy) / ll : 0.f;
            t = clamp01(t);
            const float d = std::sqrt(sq(px_ - dx * t) + sq(py_ - dy * t)) - hw;
            const float cov = clamp01(0.5f - d) * A;
            if (cov > 0.f) blend(x, y, c.r * cov, c.g * cov, c.b * cov, cov);
        }
}

void Canvas::arc(float cx, float cy, float radius, float a0, float a1, float width, const RGBA& c) {
    // angles in radians, 0 = +x, clockwise on screen (y down); round caps
    const float hw = width * 0.5f;
    const float R = radius + hw + 1.f;
    int x0 = std::max(clipX0, (int)std::floor(cx - R)), y0 = std::max(clipY0, (int)std::floor(cy - R));
    int x1 = std::min(clipX1, (int)std::ceil(cx + R)), y1 = std::min(clipY1, (int)std::ceil(cy + R));
    if (a1 < a0) std::swap(a0, a1);
    const float span = a1 - a0;
    const float mid = (a0 + a1) * 0.5f;
    const float e0x = cx + std::cos(a0) * radius, e0y = cy + std::sin(a0) * radius;
    const float e1x = cx + std::cos(a1) * radius, e1y = cy + std::sin(a1) * radius;
    const float A = c.a * globalAlpha;
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) {
            const float px_ = x + 0.5f, py_ = y + 0.5f;
            float ang = std::atan2(py_ - cy, px_ - cx);
            // bring angle near mid
            float da = ang - mid;
            while (da > 3.14159265f) da -= 6.2831853f;
            while (da < -3.14159265f) da += 6.2831853f;
            float d;
            if (std::fabs(da) <= span * 0.5f) {
                d = std::fabs(std::sqrt(sq(px_ - cx) + sq(py_ - cy)) - radius) - hw;
            } else {
                d = std::min(std::sqrt(sq(px_ - e0x) + sq(py_ - e0y)), std::sqrt(sq(px_ - e1x) + sq(py_ - e1y))) - hw;
            }
            const float cov = clamp01(0.5f - d) * A;
            if (cov > 0.f) blend(x, y, c.r * cov, c.g * cov, c.b * cov, cov);
        }
}

void Canvas::fillPoly(const float* xy, int n, const RGBA& c) {
    if (n < 3) return;
    float minx = xy[0], maxx = xy[0], miny = xy[1], maxy = xy[1];
    for (int i = 1; i < n; ++i) {
        minx = std::min(minx, xy[2 * i]);
        maxx = std::max(maxx, xy[2 * i]);
        miny = std::min(miny, xy[2 * i + 1]);
        maxy = std::max(maxy, xy[2 * i + 1]);
    }
    // orientation
    float area = 0;
    for (int i = 0; i < n; ++i) {
        const int j = (i + 1) % n;
        area += xy[2 * i] * xy[2 * j + 1] - xy[2 * j] * xy[2 * i + 1];
    }
    const float sgn = area > 0 ? 1.f : -1.f;
    std::vector<float> nx(n), ny(n), nc(n);
    for (int i = 0; i < n; ++i) {
        const int j = (i + 1) % n;
        float ex = xy[2 * j] - xy[2 * i], ey = xy[2 * j + 1] - xy[2 * i + 1];
        const float len = std::sqrt(ex * ex + ey * ey);
        if (len <= 0) { nx[i] = ny[i] = 0; nc[i] = -1e9f; continue; }
        // outward normal
        nx[i] = sgn * ey / len;
        ny[i] = -sgn * ex / len;
        nc[i] = nx[i] * xy[2 * i] + ny[i] * xy[2 * i + 1];
    }
    int x0 = std::max(clipX0, (int)std::floor(minx - 1)), y0 = std::max(clipY0, (int)std::floor(miny - 1));
    int x1 = std::min(clipX1, (int)std::ceil(maxx + 1)), y1 = std::min(clipY1, (int)std::ceil(maxy + 1));
    const float A = c.a * globalAlpha;
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) {
            float d = -1e9f;
            for (int i = 0; i < n; ++i) d = std::max(d, nx[i] * (x + 0.5f) + ny[i] * (y + 0.5f) - nc[i]);
            const float cov = clamp01(0.5f - d) * A;
            if (cov > 0.f) blend(x, y, c.r * cov, c.g * cov, c.b * cov, cov);
        }
}

void Canvas::shadow(const Rc& r, float radius, float blur, const RGBA& c, float dy, float spread) {
    const float sigma = std::max(0.5f, blur * 0.5f);
    const Rc s{r.x - spread, r.y - spread + dy, r.w + 2 * spread, r.h + 2 * spread};
    const float ext = sigma * 2.6f;
    int x0 = std::max(clipX0, (int)std::floor(s.x - ext)), y0 = std::max(clipY0, (int)std::floor(s.y - ext));
    int x1 = std::min(clipX1, (int)std::ceil(s.r() + ext)), y1 = std::min(clipY1, (int)std::ceil(s.b() + ext));
    if (x0 >= x1 || y0 >= y1) return;
    const float hw = s.w * 0.5f, hh = s.h * 0.5f, cx = s.cx(), cy = s.cy();
    const float rad = std::max(0.f, std::min({radius + spread, hw, hh}));
    const float ohw = r.w * 0.5f, ohh = r.h * 0.5f, ocx = r.cx(), ocy = r.cy();
    const float orad = std::max(0.f, std::min({radius, ohw, ohh}));
    const bool same = dy == 0.f && spread == 0.f;
    const float A = c.a * globalAlpha;
    if (A <= 0.f) return;
    // gaussian edge profile as a lookup table over the signed distance
    constexpr int N = 96;
    float lut[N + 2];
    const float inv = 1.f / (sigma * 1.41421356f);
    for (int i = 0; i <= N + 1; ++i) {
        const float d = -ext + 2.f * ext * (float)i / N;
        lut[i] = 0.5f * (1.f - erfApprox(d * inv)) * A;
    }
    const float toLut = N / (2.f * ext);
    const float cr = c.r * 255.f, cg = c.g * 255.f, cb = c.b * 255.f;
    if (rad <= sigma * 1.6f) {
        // Gaussian blur of a box is separable: alpha = Fx(x) * Fy(y). For corner
        // radii that are small next to the blur the rounding is invisible, and this
        // costs one multiply per pixel instead of a distance field evaluation.
        static thread_local std::vector<float> fx, fy;
        fx.resize((size_t)(x1 - x0));
        fy.resize((size_t)(y1 - y0));
        for (int x = x0; x < x1; ++x) {
            const float p = x + 0.5f;
            fx[x - x0] = 0.5f * (erfApprox((p - s.x) * inv) - erfApprox((p - s.r()) * inv));
        }
        for (int y = y0; y < y1; ++y) {
            const float p = y + 0.5f;
            fy[y - y0] = 0.5f * (erfApprox((p - s.y) * inv) - erfApprox((p - s.b()) * inv)) * A;
        }
        const int bx0 = (int)std::floor(r.x) - 1, bx1 = (int)std::ceil(r.r()) + 1;
        const int by0 = (int)std::floor(r.y) - 1, by1 = (int)std::ceil(r.b()) + 1;
        for (int y = y0; y < y1; ++y) {
            const float pyc = y + 0.5f;
            const float ay = fy[y - y0];
            if (ay < 0.002f) continue;
            int xs = 1, xe = 0;
            const bool inner = roundRectFullSpan(pyc, ocx, ocy, ohw, ohh, orad, xs, xe);
            const bool rowNearShape = y >= by0 && y < by1;
            for (int x = x0; x < x1; ++x) {
                if (inner && x >= xs && x <= xe) {
                    x = xe;
                    continue;
                }
                float a = ay * fx[x - x0];
                if (a < 0.002f) continue;
                if (rowNearShape && x >= bx0 && x < bx1) {
                    const float covShape = clamp01(0.5f - sdRoundRect(x + 0.5f, pyc, ocx, ocy, ohw, ohh, orad));
                    a *= 1.f - covShape;
                    if (a < 0.002f) continue;
                }
                const uint32_t ia8 = (uint32_t)(a * 255.f + 0.5f);
                if (!ia8) continue;
                uint32_t& dp = px[(size_t)y * stride + x];
                dp = overPixel(dp, (std::min(ia8, (uint32_t)(cb * a + 0.5f))) |
                                       (std::min(ia8, (uint32_t)(cg * a + 0.5f)) << 8) |
                                       (std::min(ia8, (uint32_t)(cr * a + 0.5f)) << 16) | (ia8 << 24));
            }
        }
        return;
    }
    for (int y = y0; y < y1; ++y) {
        const float pyc = y + 0.5f;
        int xs = 1, xe = 0;  // shadow is hidden under the (opaque-looking) shape itself
        const bool inner = roundRectFullSpan(pyc, ocx, ocy, ohw, ohh, orad, xs, xe);
        for (int x = x0; x < x1; ++x) {
            if (inner && x >= xs && x <= xe) {
                x = xe;
                continue;
            }
            const float pxc = x + 0.5f;
            const float d = sdRoundRect(pxc, pyc, cx, cy, hw, hh, rad);
            if (d >= ext) continue;
            const float ds = same ? d : sdRoundRect(pxc, pyc, ocx, ocy, ohw, ohh, orad);
            const float covShape = clamp01(0.5f - ds);
            if (covShape >= 1.f) continue;
            const float fi = (std::max(d, -ext) + ext) * toLut;
            const int i0 = (int)fi;
            const float fr = fi - (float)i0;
            const float a = (lut[i0] + (lut[i0 + 1] - lut[i0]) * fr) * (1.f - covShape);
            if (a > 0.002f) blend(x, y, c.r * a, c.g * a, c.b * a, a);
        }
    }
}

void Canvas::glowBlob(float x, float y, float rx, float ry, const RGBA& c) {
    int x0 = std::max(clipX0, (int)std::floor(x - rx * 1.6f)), y0 = std::max(clipY0, (int)std::floor(y - ry * 1.6f));
    int x1 = std::min(clipX1, (int)std::ceil(x + rx * 1.6f)), y1 = std::min(clipY1, (int)std::ceil(y + ry * 1.6f));
    const float A = c.a * globalAlpha;
    for (int yy = y0; yy < y1; ++yy)
        for (int xx = x0; xx < x1; ++xx) {
            const float u = (xx + 0.5f - x) / rx, v = (yy + 0.5f - y) / ry;
            const float d2 = u * u + v * v;
            if (d2 >= 2.56f) continue;
            float a = std::exp(-d2 * 2.2f) * A;
            // fade to exactly zero at the boundary
            a *= clamp01((2.56f - d2) * 2.f);
            if (a > 0.001f) blend(xx, yy, c.r * a, c.g * a, c.b * a, a);
        }
}

void Canvas::drawImage(const uint32_t* src, int sw, int sh, int sstride, int dx, int dy) {
    const int x0 = std::max(clipX0, dx), y0 = std::max(clipY0, dy);
    const int x1 = std::min(clipX1, dx + sw), y1 = std::min(clipY1, dy + sh);
    if (x0 >= x1 || y0 >= y1) return;
    const uint32_t ga = (uint32_t)(std::max(0.f, std::min(1.f, globalAlpha)) * 256.f + 0.5f);
    if (ga == 0) return;
    for (int y = y0; y < y1; ++y) {
        const uint32_t* s = src + (size_t)(y - dy) * sstride + (x0 - dx);
        uint32_t* d = px + (size_t)y * stride + x0;
        int n = x1 - x0, i = 0;
#ifdef VX_SSE2
        if (ga >= 256) {
            const __m128i zero = _mm_setzero_si128();
            const __m128i c255 = _mm_set1_epi16(255), r128 = _mm_set1_epi16(128);
            for (; i + 4 <= n; i += 4) {
                const __m128i sv = _mm_loadu_si128((const __m128i*)(s + i));
                const __m128i dv = _mm_loadu_si128((const __m128i*)(d + i));
                const __m128i slo = _mm_unpacklo_epi8(sv, zero), shi = _mm_unpackhi_epi8(sv, zero);
                // broadcast each pixel's alpha to its four 16-bit lanes and invert
                __m128i alo = _mm_shufflehi_epi16(_mm_shufflelo_epi16(slo, 0xFF), 0xFF);
                __m128i ahi = _mm_shufflehi_epi16(_mm_shufflelo_epi16(shi, 0xFF), 0xFF);
                alo = _mm_sub_epi16(c255, alo);
                ahi = _mm_sub_epi16(c255, ahi);
                __m128i lo = _mm_add_epi16(_mm_mullo_epi16(_mm_unpacklo_epi8(dv, zero), alo), r128);
                __m128i hi = _mm_add_epi16(_mm_mullo_epi16(_mm_unpackhi_epi8(dv, zero), ahi), r128);
                lo = _mm_srli_epi16(_mm_add_epi16(lo, _mm_srli_epi16(lo, 8)), 8);
                hi = _mm_srli_epi16(_mm_add_epi16(hi, _mm_srli_epi16(hi, 8)), 8);
                _mm_storeu_si128((__m128i*)(d + i), _mm_packus_epi16(_mm_add_epi16(lo, slo), _mm_add_epi16(hi, shi)));
            }
        }
#endif
        for (; i < n; ++i) {
            uint32_t sp = s[i];
            if (ga < 256) {  // scale all four premultiplied channels
                const uint32_t rb = ((sp & 0x00FF00FFu) * ga >> 8) & 0x00FF00FFu;
                const uint32_t ag = (((sp >> 8) & 0x00FF00FFu) * ga) & 0xFF00FF00u;
                sp = rb | ag;
            }
            if ((sp >> 24) == 0) continue;
            d[i] = overPixel(d[i], sp);
        }
    }
}

void Canvas::blit(const uint32_t* src, int sw, int sh, int sstride, int dx, int dy, int scale) {
    if (scale < 1) scale = 1;
    const int x0 = std::max(clipX0, dx), y0 = std::max(clipY0, dy);
    const int x1 = std::min(clipX1, dx + sw * scale), y1 = std::min(clipY1, dy + sh * scale);
    for (int y = y0; y < y1; ++y) {
        const uint32_t* srow = src + (size_t)((y - dy) / scale) * sstride;
        for (int x = x0; x < x1; ++x) {
            const uint32_t s = srow[(x - dx) / scale];
            const uint32_t sa = s >> 24;
            if (sa == 0) continue;
            const float ga = globalAlpha;
            blend(x, y, ((s >> 16) & 255) / 255.f * ga, ((s >> 8) & 255) / 255.f * ga, (s & 255) / 255.f * ga,
                  sa / 255.f * ga);
        }
    }
}

// ================================================================= text

uint32_t utf8Next(const std::string& s, size_t& i) {
    const unsigned char c = (unsigned char)s[i++];
    if (c < 0x80) return c;
    auto cont = [&](uint32_t v, int n) {
        for (int k = 0; k < n; ++k) {
            if (i >= s.size()) return 0xFFFDu;
            v = (v << 6) | ((unsigned char)s[i++] & 0x3F);
        }
        return v;
    };
    if ((c >> 5) == 6) return cont(c & 0x1F, 1);
    if ((c >> 4) == 14) return cont(c & 0x0F, 2);
    if ((c >> 3) == 30) return cont(c & 0x07, 3);
    return 0xFFFD;
}

struct TextEngine::Face {
    stbtt_fontinfo info{};
    int ascent = 0, descent = 0, gap = 0, capH = 0, xH = 0;
    float emScale1 = 0;  // scale for 1px em
    std::unordered_map<uint32_t, int> gidCache;
    int gid(uint32_t cp) {
        auto it = gidCache.find(cp);
        if (it != gidCache.end()) return it->second;
        const int g = stbtt_FindGlyphIndex(&info, (int)cp);
        gidCache[cp] = g;
        return g;
    }
};

TextEngine& text() {
    static TextEngine t;
    return t;
}

bool TextEngine::init() {
    if (!faces_.empty()) return true;
    const uint8_t* blobs[4] = {fontdata::kRegular, fontdata::kMedium, fontdata::kSemiBold, fontdata::kBold};
    for (auto* b : blobs) {
        Face* f = new Face();
        if (!stbtt_InitFont(&f->info, b, stbtt_GetFontOffsetForIndex(b, 0))) {
            delete f;
            return false;
        }
        stbtt_GetFontVMetrics(&f->info, &f->ascent, &f->descent, &f->gap);
        f->emScale1 = stbtt_ScaleForMappingEmToPixels(&f->info, 1.f);
        // cap height / x height from glyph boxes
        int x0, y0, x1, y1;
        if (stbtt_GetCodepointBox(&f->info, 'H', &x0, &y0, &x1, &y1)) f->capH = y1;
        if (stbtt_GetCodepointBox(&f->info, 'x', &x0, &y0, &x1, &y1)) f->xH = y1;
        faces_.push_back(f);
    }
    return true;
}

float TextEngine::capHeight(int face, float size) const {
    const Face* f = faces_[face];
    return f->capH * f->emScale1 * size;
}

float TextEngine::xHeight(int face, float size) const {
    const Face* f = faces_[face];
    return f->xH * f->emScale1 * size;
}

const TextEngine::Glyph& TextEngine::glyph(int face, int gid, float size, int sub) {
    const uint64_t key = ((uint64_t)face << 60) | ((uint64_t)(int)(size * 8.f + 0.5f) << 40) |
                         ((uint64_t)sub << 36) | (uint64_t)gid;
    auto it = cache_.find(key);
    if (it != cache_.end()) return it->second;
    Face* f = faces_[face];
    const float scale = f->emScale1 * size;
    const float shift = sub * 0.25f;
    Glyph g;
    int x0, y0, x1, y1;
    stbtt_GetGlyphBitmapBoxSubpixel(&f->info, gid, scale, scale, shift, 0.f, &x0, &y0, &x1, &y1);
    g.w = x1 - x0;
    g.h = y1 - y0;
    g.x0 = x0;
    g.y0 = y0;
    if (g.w > 0 && g.h > 0) {
        g.a.resize((size_t)g.w * g.h);
        stbtt_MakeGlyphBitmapSubpixel(&f->info, g.a.data(), g.w, g.h, g.w, scale, scale, shift, 0.f, gid);
    }
    return cache_.emplace(key, std::move(g)).first->second;
}

float TextEngine::measure(int face, float size, const std::string& s, float tracking) {
    if (faces_.empty() && !init()) return 0.f;
    Face* f = faces_[face];
    const float scale = f->emScale1 * size;
    float x = 0;
    int prev = -1;
    size_t i = 0;
    int count = 0;
    while (i < s.size()) {
        const uint32_t cp = utf8Next(s, i);
        const int g = f->gid(cp);
        if (prev >= 0) x += stbtt_GetGlyphKernAdvance(&f->info, prev, g) * scale;
        int adv, lsb;
        stbtt_GetGlyphHMetrics(&f->info, g, &adv, &lsb);
        x += adv * scale + tracking;
        prev = g;
        ++count;
    }
    if (count > 0) x -= tracking;
    return x;
}

float TextEngine::draw(Canvas& c, int face, float size, float x, float y, const std::string& s, const RGBA& col,
                       float tracking) {
    if (faces_.empty() && !init()) return 0.f;
    Face* f = faces_[face];
    const float scale = f->emScale1 * size;
    const int by = (int)std::floor(y + 0.5f);
    // light text on dark backgrounds is perceived thinner with sRGB blending; compensate a bit
    const float lum = 0.2126f * col.r + 0.7152f * col.g + 0.0722f * col.b;
    static float lutLight[256], lutDark[256];
    static bool lutInit = false;
    if (!lutInit) {
        for (int i = 0; i < 256; ++i) {
            lutLight[i] = std::pow(i / 255.f, 0.80f);
            lutDark[i] = std::pow(i / 255.f, 1.12f);
        }
        lutInit = true;
    }
    const float* lut = lum > 0.5f ? lutLight : lutDark;
    const float A = col.a * c.globalAlpha;
    float pen = x;
    int prev = -1;
    size_t i = 0;
    while (i < s.size()) {
        const uint32_t cp = utf8Next(s, i);
        const int gid = f->gid(cp);
        if (prev >= 0) pen += stbtt_GetGlyphKernAdvance(&f->info, prev, gid) * scale;
        int adv, lsb;
        stbtt_GetGlyphHMetrics(&f->info, gid, &adv, &lsb);
        const float fl = std::floor(pen);
        int sub = (int)((pen - fl) * 4.f + 0.5f);
        int ix = (int)fl;
        if (sub == 4) { sub = 0; ++ix; }
        const Glyph& g = glyph(face, gid, size, sub);
        if (g.w > 0) {
            const int gx0 = ix + g.x0, gy0 = by + g.y0;
            const int sx0 = std::max(c.clipX0, gx0), sy0 = std::max(c.clipY0, gy0);
            const int sx1 = std::min(c.clipX1, gx0 + g.w), sy1 = std::min(c.clipY1, gy0 + g.h);
            for (int yy = sy0; yy < sy1; ++yy) {
                const uint8_t* src = &g.a[(size_t)(yy - gy0) * g.w];
                for (int xx = sx0; xx < sx1; ++xx) {
                    const uint8_t v = src[xx - gx0];
                    if (!v) continue;
                    const float a = lut[v] * A;
                    c.blend(xx, yy, col.r * a, col.g * a, col.b * a, a);
                }
            }
        }
        pen += adv * scale + tracking;
        prev = gid;
    }
    return pen - x;
}

float TextEngine::drawGradient(Canvas& c, int face, float size, float x, float y, const std::string& s, const RGBA& c0,
                               const RGBA& c1, float tracking) {
    if (faces_.empty() && !init()) return 0.f;
    const float w = std::max(1.f, measure(face, size, s, tracking));
    Face* f = faces_[face];
    const float scale = f->emScale1 * size;
    const int by = (int)std::floor(y + 0.5f);
    static float lut[256];
    static bool lutInit = false;
    if (!lutInit) {
        for (int i = 0; i < 256; ++i) lut[i] = std::pow(i / 255.f, 0.80f);
        lutInit = true;
    }
    float pen = x;
    int prev = -1;
    size_t i = 0;
    while (i < s.size()) {
        const uint32_t cp = utf8Next(s, i);
        const int gid = f->gid(cp);
        if (prev >= 0) pen += stbtt_GetGlyphKernAdvance(&f->info, prev, gid) * scale;
        int adv, lsb;
        stbtt_GetGlyphHMetrics(&f->info, gid, &adv, &lsb);
        const float fl = std::floor(pen);
        int sub = (int)((pen - fl) * 4.f + 0.5f);
        int ix = (int)fl;
        if (sub == 4) { sub = 0; ++ix; }
        const Glyph& g = glyph(face, gid, size, sub);
        if (g.w > 0) {
            const int gx0 = ix + g.x0, gy0 = by + g.y0;
            const int sx0 = std::max(c.clipX0, gx0), sy0 = std::max(c.clipY0, gy0);
            const int sx1 = std::min(c.clipX1, gx0 + g.w), sy1 = std::min(c.clipY1, gy0 + g.h);
            for (int yy = sy0; yy < sy1; ++yy) {
                const uint8_t* src = &g.a[(size_t)(yy - gy0) * g.w];
                for (int xx = sx0; xx < sx1; ++xx) {
                    const uint8_t v = src[xx - gx0];
                    if (!v) continue;
                    const RGBA col = mix(c0, c1, std::max(0.f, std::min(1.f, (xx + 0.5f - x) / w)));
                    const float a = lut[v] * col.a * c.globalAlpha;
                    c.blend(xx, yy, col.r * a, col.g * a, col.b * a, a);
                }
            }
        }
        pen += adv * scale + tracking;
        prev = gid;
    }
    return pen - x;
}

float TextEngine::drawIn(Canvas& c, int face, float size, const Rc& r, const std::string& s, const RGBA& col,
                         int align, float tracking) {
    const float w = measure(face, size, s, tracking);
    float x = r.x;
    if (align == 1) x = r.x + (r.w - w) * 0.5f;
    if (align == 2) x = r.r() - w;
    const float baseline = r.cy() + capHeight(face, size) * 0.5f;
    draw(c, face, size, x, baseline, s, col, tracking);
    return w;
}

std::string TextEngine::ellipsize(int face, float size, const std::string& s, float maxW, float tracking) {
    if (measure(face, size, s, tracking) <= maxW) return s;
    std::string t = s;
    while (!t.empty()) {
        // drop last UTF-8 code point
        size_t k = t.size() - 1;
        while (k > 0 && ((unsigned char)t[k] & 0xC0) == 0x80) --k;
        t.erase(k);
        if (measure(face, size, t + "\xE2\x80\xA6", tracking) <= maxW) return t + "\xE2\x80\xA6";
    }
    return t;
}

}  // namespace vx
