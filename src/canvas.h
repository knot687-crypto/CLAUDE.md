// Vortex Crosshair - tiny anti-aliased software 2D renderer (portable C++17)
// Draws into a premultiplied BGRA buffer (the native Windows 32-bit DIB layout).
#pragma once
#include <cmath>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "crosshair.h"  // RGBA

namespace vx {

struct Rc {
    float x = 0, y = 0, w = 0, h = 0;
    float r() const { return x + w; }
    float b() const { return y + h; }
    float cx() const { return x + w * 0.5f; }
    float cy() const { return y + h * 0.5f; }
    bool contains(float px, float py) const { return px >= x && px < x + w && py >= y && py < y + h; }
    Rc inset(float d) const { return Rc{x + d, y + d, w - 2 * d, h - 2 * d}; }
    Rc inset(float dx, float dy) const { return Rc{x + dx, y + dy, w - 2 * dx, h - 2 * dy}; }
    Rc offset(float dx, float dy) const { return Rc{x + dx, y + dy, w, h}; }
};

RGBA hexc(uint32_t rgb, float a = 1.f);
inline RGBA mix(const RGBA& a, const RGBA& b, float t) {
    return RGBA{a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t};
}
inline RGBA alpha(RGBA c, float a) { c.a *= a; return c; }

class Canvas {
public:
    uint32_t* px = nullptr;
    int w = 0, h = 0, stride = 0;
    int clipX0 = 0, clipY0 = 0, clipX1 = 0, clipY1 = 0;
    float globalAlpha = 1.f;  // multiplies every draw (used for fades)
    std::vector<int> clipStack;

    void attach(uint32_t* p, int width, int height, int strideInPixels);
    void setClip(int x0, int y0, int x1, int y1);
    void setClip(const Rc& r);
    void resetClip();
    // Intersect the clip with r (saving the previous clip) / restore it.
    void pushClip(const Rc& r);
    void popClip();
    void clear(uint32_t premulBGRA = 0);
    void clearRect(int x0, int y0, int x1, int y1, uint32_t premulBGRA = 0);

    void fillRect(const Rc& r, const RGBA& c);
    void fillRoundRect(const Rc& r, float radius, const RGBA& c);
    void fillRoundRectGrad(const Rc& r, float radius, const RGBA& c0, const RGBA& c1, bool vertical = true);
    // Border drawn inside the rectangle.
    void strokeRoundRect(const Rc& r, float radius, float width, const RGBA& c);
    void strokeRoundRectGrad(const Rc& r, float radius, float width, const RGBA& top, const RGBA& bottom);
    void fillCircle(float x, float y, float radius, const RGBA& c);
    void strokeCircle(float x, float y, float radius, float width, const RGBA& c);
    void line(float x0, float y0, float x1, float y1, float width, const RGBA& c);
    void arc(float x, float y, float radius, float a0, float a1, float width, const RGBA& c);
    void fillPoly(const float* xy, int n, const RGBA& c);  // convex polygon
    // Soft drop shadow drawn only outside the rounded rect.
    void shadow(const Rc& r, float radius, float blur, const RGBA& c, float dy = 0.f, float spread = 0.f);
    // Soft radial blob (gaussian-like falloff).
    void glowBlob(float x, float y, float rx, float ry, const RGBA& c);
    // Arbitrary paint inside a rounded rect. f(x, y, float out[4]) writes straight RGBA.
    template <class F>
    void paintRoundRect(const Rc& r, float radius, F&& f);
    // Arbitrary paint inside the border ring (width px, inside the rect) of a rounded rect.
    template <class F>
    void paintRing(const Rc& r, float radius, float width, F&& f);
    // Copy (blend) a premultiplied image, optionally scaled by an integer factor (nearest).
    void blit(const uint32_t* src, int sw, int sh, int sstride, int dx, int dy, int scale = 1);

    // Blend a premultiplied image (top-left at dx, dy), honouring clip and globalAlpha.
    void drawImage(const uint32_t* src, int sw, int sh, int sstride, int dx, int dy);

    inline void blend(int x, int y, float r, float g, float b, float a) {  // premultiplied 0..1
        uint32_t& d = px[(size_t)y * stride + x];
        const float ia = 1.f - a;
        int ob = (int)(b * 255.f + (float)(d & 255) * ia + 0.5f);
        int og = (int)(g * 255.f + (float)((d >> 8) & 255) * ia + 0.5f);
        int orr = (int)(r * 255.f + (float)((d >> 16) & 255) * ia + 0.5f);
        int oa = (int)(a * 255.f + (float)(d >> 24) * ia + 0.5f);
        ob = ob > 255 ? 255 : (ob < 0 ? 0 : ob);
        og = og > 255 ? 255 : (og < 0 ? 0 : og);
        orr = orr > 255 ? 255 : (orr < 0 ? 0 : orr);
        oa = oa > 255 ? 255 : (oa < 0 ? 0 : oa);
        d = (uint32_t)ob | ((uint32_t)og << 8) | ((uint32_t)orr << 16) | ((uint32_t)oa << 24);
    }
};

// Pixels [xs, xe] of the row whose centre is py are fully covered by the rounded
// rect (centre cx, cy, half sizes hw, hh, corner radius rad). Returns false if none.
inline bool roundRectFullSpan(float py, float cx, float cy, float hw, float hh, float rad, int& xs, int& xe) {
    const float qy = std::fabs(py - cy) - (hh - rad);
    if (qy > rad - 0.5f) return false;
    float qxMax;
    if (qy <= 0.f) {
        qxMax = rad - 0.5f;
    } else {
        const float r2 = (rad - 0.5f) * (rad - 0.5f) - qy * qy;
        qxMax = r2 > 0.f ? std::sqrt(r2) : 0.f;
    }
    const float half = hw - rad + qxMax;
    if (half <= 0.f) return false;
    xs = (int)std::ceil(cx - half - 0.5f);
    xe = (int)std::floor(cx + half - 0.5f);
    return xs <= xe;
}

// ---------------------------------------------------------------- text
enum FontFace { FONT_REGULAR = 0, FONT_MEDIUM = 1, FONT_SEMIBOLD = 2, FONT_BOLD = 3 };

class TextEngine {
public:
    bool init();
    float measure(int face, float size, const std::string& s, float tracking = 0.f);
    // Draws text with its baseline at y. Returns the advance.
    float draw(Canvas& c, int face, float size, float x, float y, const std::string& s, const RGBA& col,
               float tracking = 0.f);
    // Same as draw() but with a horizontal colour gradient across the text.
    float drawGradient(Canvas& c, int face, float size, float x, float y, const std::string& s, const RGBA& c0,
                       const RGBA& c1, float tracking = 0.f);
    float capHeight(int face, float size) const;
    float xHeight(int face, float size) const;
    // Convenience: draws text vertically centred (on cap height) in rect, aligned 0=left 1=center 2=right
    float drawIn(Canvas& c, int face, float size, const Rc& r, const std::string& s, const RGBA& col,
                 int align = 0, float tracking = 0.f);
    // Truncate with "..." to fit width.
    std::string ellipsize(int face, float size, const std::string& s, float maxW, float tracking = 0.f);

private:
    struct Glyph {
        int w = 0, h = 0, x0 = 0, y0 = 0;
        std::vector<uint8_t> a;
    };
    struct Face;
    std::vector<Face*> faces_;
    std::unordered_map<uint64_t, Glyph> cache_;
    const Glyph& glyph(int face, int gid, float size, int sub);
};

TextEngine& text();

// UTF-8 decoding helper
uint32_t utf8Next(const std::string& s, size_t& i);

// ---------------------------------------------------------------- template impl
inline float sdRoundRect(float px, float py, float cx, float cy, float hw, float hh, float r) {
    const float qx = std::fabs(px - cx) - (hw - r);
    const float qy = std::fabs(py - cy) - (hh - r);
    const float ox = qx > 0 ? qx : 0, oy = qy > 0 ? qy : 0;
    const float m = qx > qy ? qx : qy;
    return std::sqrt(ox * ox + oy * oy) + (m < 0.f ? m : 0.f) - r;
}

template <class F>
void Canvas::paintRoundRect(const Rc& r, float radius, F&& f) {
    if (r.w <= 0 || r.h <= 0) return;
    int x0 = (int)std::floor(r.x), y0 = (int)std::floor(r.y);
    int x1 = (int)std::ceil(r.r()), y1 = (int)std::ceil(r.b());
    if (x0 < clipX0) x0 = clipX0;
    if (y0 < clipY0) y0 = clipY0;
    if (x1 > clipX1) x1 = clipX1;
    if (y1 > clipY1) y1 = clipY1;
    const float hw = r.w * 0.5f, hh = r.h * 0.5f, cx = r.cx(), cy = r.cy();
    float rad = radius;
    if (rad > hw) rad = hw;
    if (rad > hh) rad = hh;
    if (rad < 0.f) rad = 0.f;
    float out[4];
    for (int y = y0; y < y1; ++y) {
        const float py = y + 0.5f;
        int xs = 1, xe = 0;
        const bool span = roundRectFullSpan(py, cx, cy, hw, hh, rad, xs, xe);
        for (int x = x0; x < x1; ++x) {
            float cov = 1.f;
            if (!span || x < xs || x > xe) {
                cov = 0.5f - sdRoundRect(x + 0.5f, py, cx, cy, hw, hh, rad);
                if (cov <= 0.f) continue;
                if (cov > 1.f) cov = 1.f;
            }
            f(x + 0.5f, py, out);
            const float a = out[3] * cov * globalAlpha;
            if (a <= 0.f) continue;
            blend(x, y, out[0] * a, out[1] * a, out[2] * a, a);
        }
    }
}

template <class F>
void Canvas::paintRing(const Rc& r, float radius, float width, F&& f) {
    if (r.w <= 0 || r.h <= 0 || width <= 0) return;
    int x0 = (int)std::floor(r.x), y0 = (int)std::floor(r.y);
    int x1 = (int)std::ceil(r.r()), y1 = (int)std::ceil(r.b());
    if (x0 < clipX0) x0 = clipX0;
    if (y0 < clipY0) y0 = clipY0;
    if (x1 > clipX1) x1 = clipX1;
    if (y1 > clipY1) y1 = clipY1;
    const float hw = r.w * 0.5f, hh = r.h * 0.5f, cx = r.cx(), cy = r.cy();
    float rad = radius;
    if (rad > hw) rad = hw;
    if (rad > hh) rad = hh;
    if (rad < 0.f) rad = 0.f;
    const float iw = hw - width, ih = hh - width, irad = rad > width ? rad - width : 0.f;
    float out[4];
    for (int y = y0; y < y1; ++y) {
        const float py = y + 0.5f;
        // pixels fully inside the inner shape (the hole) have no ring coverage
        int hs = 1, he = 0;
        const bool hole = iw > 0.5f && ih > 0.5f && roundRectFullSpan(py, cx, cy, iw, ih, irad, hs, he);
        for (int x = x0; x < x1; ++x) {
            if (hole && x >= hs && x <= he) {
                x = he;
                continue;
            }
            const float pxc = x + 0.5f;
            float co = 0.5f - sdRoundRect(pxc, py, cx, cy, hw, hh, rad);
            if (co <= 0.f) continue;
            if (co > 1.f) co = 1.f;
            float ci = 0.f;
            if (iw > 0.f && ih > 0.f) {
                ci = 0.5f - sdRoundRect(pxc, py, cx, cy, iw, ih, irad);
                ci = ci < 0.f ? 0.f : (ci > 1.f ? 1.f : ci);
            }
            const float cov = co - ci;
            if (cov <= 0.f) continue;
            f(pxc, py, out);
            const float a = out[3] * cov * globalAlpha;
            if (a <= 0.f) continue;
            blend(x, y, out[0] * a, out[1] * a, out[2] * a, a);
        }
    }
}

}  // namespace vx
