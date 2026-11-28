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
RGBA mix(const RGBA& a, const RGBA& b, float t);
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
    // Copy (blend) a premultiplied image, optionally scaled by an integer factor (nearest).
    void blit(const uint32_t* src, int sw, int sh, int sstride, int dx, int dy, int scale = 1);

    void blend(int x, int y, float r, float g, float b, float a);  // premultiplied 0..1
};

// ---------------------------------------------------------------- text
enum FontFace { FONT_REGULAR = 0, FONT_MEDIUM = 1, FONT_SEMIBOLD = 2, FONT_BOLD = 3 };

class TextEngine {
public:
    bool init();
    float measure(int face, float size, const std::string& s, float tracking = 0.f);
    // Draws text with its baseline at y. Returns the advance.
    float draw(Canvas& c, int face, float size, float x, float y, const std::string& s, const RGBA& col,
               float tracking = 0.f);
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
float sdRoundRect(float px, float py, float cx, float cy, float hw, float hh, float r);

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
    float out[4];
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            const float d = sdRoundRect(x + 0.5f, y + 0.5f, cx, cy, hw, hh, rad);
            float cov = 0.5f - d;
            if (cov <= 0.f) continue;
            if (cov > 1.f) cov = 1.f;
            f(x + 0.5f, y + 0.5f, out);
            const float a = out[3] * cov * globalAlpha;
            if (a <= 0.f) continue;
            blend(x, y, out[0] * a, out[1] * a, out[2] * a, a);
        }
    }
}

}  // namespace vx
