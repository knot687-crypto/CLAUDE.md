// Vortex Crosshair - glass settings panel (immediate mode, software rendered)
//
// Visual language: frosted dark glass lit by soft aurora light in the crosshair's
// accent colour, fine grain, gradient hairline borders, colour-coded icon tiles,
// spring physics for switches/selectors, click ripples and a staggered entrance.
#include "ui.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace vx {

namespace {

constexpr float kPi = 3.14159265358979f;

constexpr uint32_t fnv(const char* s, uint32_t h = 2166136261u) {
    return *s ? fnv(s + 1, (h ^ (uint8_t)*s) * 16777619u) : h;
}
inline uint32_t ID(const char* s, int i = 0) { return fnv(s) ^ ((uint32_t)i * 0x9E3779B1u); }

inline float clamp01(float v) { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }
inline float smooth(float t) { t = clamp01(t); return t * t * (3.f - 2.f * t); }
inline float easeOut(float t) { t = clamp01(t); return 1.f - (1.f - t) * (1.f - t) * (1.f - t); }

const RGBA kWhite{1, 1, 1, 1};
inline RGBA W(float a) { return RGBA{1, 1, 1, a}; }
inline RGBA Bk(float a) { return RGBA{0, 0, 0, a}; }

enum Icon {
    IC_COLORS, IC_SHAPE, IC_MOTION, IC_EFFECTS, IC_SETTINGS, IC_CLOSE, IC_POWER, IC_RESET, IC_COPY, IC_CHECK,
    IC_CURSOR, IC_TARGET, IC_KEY
};

const char* kPageNames[5] = {"Colors", "Shape", "Motion", "Effects", "Settings"};
const char* kPageDesc[5] = {
    "Paint every part of the crosshair. Changes apply live.",
    "Proportions of the blades and the center dot.",
    "Spin speed, direction and click reactions.",
    "Glow, halo and visibility helpers.",
    "Placement, pointer, hotkeys and startup.",
};
// icon tile gradients per page (top, bottom)
const RGBA kTileTop[5] = {{1.00f, 0.47f, 0.68f, 1}, {0.72f, 0.55f, 1.00f, 1}, {0.33f, 0.80f, 1.00f, 1},
                          {1.00f, 0.80f, 0.38f, 1}, {0.70f, 0.73f, 0.81f, 1}};
const RGBA kTileBot[5] = {{0.96f, 0.30f, 0.42f, 1}, {0.42f, 0.33f, 0.96f, 1}, {0.18f, 0.46f, 0.98f, 1},
                          {0.98f, 0.48f, 0.26f, 1}, {0.38f, 0.41f, 0.50f, 1}};

const uint32_t kSwatches[12] = {0xFFFFFF, 0xFFC8D2, 0xFF5FA2, 0xFF3B4E, 0xFF8A2B, 0xFFE14D,
                                0x9DFF4D, 0x2BFF9A, 0x2BE3FF, 0x4D8DFF, 0x9D6BFF, 0xEA5BFF};

std::string fmtInt(float v, const char* suffix) {
    char b[32];
    std::snprintf(b, sizeof(b), "%d%s", (int)std::lround(v), suffix);
    return b;
}
std::string fmt1(float v, const char* suffix) {
    char b[32];
    std::snprintf(b, sizeof(b), "%.1f%s", v, suffix);
    return b;
}

// cheap per-pixel hash for the glass grain
inline float hash01(int x, int y) {
    uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= h >> 16;
    return (h & 0xFFFF) / 65535.f;
}

}  // namespace

// ============================================================ basics

float SettingsPanel::anim(uint32_t id, float target, float speed) {
    auto it = anim_.find(id);
    if (it == anim_.end()) {
        anim_[id] = target;
        return target;
    }
    float& v = it->second;
    const float k = 1.f - std::exp(-speed * std::min(in_.dt, 0.1f));
    v += (target - v) * k;
    if (std::fabs(target - v) < 0.002f)
        v = target;
    else
        animating_ = true;
    return v;
}

float SettingsPanel::spring(uint32_t id, float target, float stiffness, float damping) {
    auto it = springs_.find(id);
    if (it == springs_.end()) {
        springs_[id] = Spring{target, 0.f};
        return target;
    }
    Spring& sp = it->second;
    const float dt = std::min(in_.dt, 1.f / 30.f);
    const int n = 4;
    const float h = dt / n;
    for (int i = 0; i < n; ++i) {
        const float a = stiffness * (target - sp.x) - damping * sp.v;
        sp.v += a * h;
        sp.x += sp.v * h;
    }
    if (std::fabs(target - sp.x) < 0.0015f && std::fabs(sp.v) < 0.01f) {
        sp.x = target;
        sp.v = 0.f;
    } else {
        animating_ = true;
    }
    return sp.x;
}

bool SettingsPanel::hovered(const Rc& r) const { return r.contains(in_.mx, in_.my); }

bool SettingsPanel::behave(uint32_t id, const Rc& r, bool* hover, bool* held) {
    const bool over = hovered(r) && (active_ == 0 || active_ == id);
    if (over) hot_ = id;
    bool clicked = false;
    if (over && in_.mousePressed) {
        active_ = id;
        if (focus_ != id) focus_ = 0;
        Ripple& rp = ripples_[id];
        rp.t0 = in_.time;
        rp.x = in_.mx;
        rp.y = in_.my;
    }
    if (active_ == id && in_.mouseReleased && hovered(r)) clicked = true;
    if (hover) *hover = over;
    if (held) *held = active_ == id && in_.mouseDown;
    if (over) out_->cursor = CURSOR_HAND;
    return clicked;
}

void SettingsPanel::label(float x, float y, const std::string& t, float size, int face, const RGBA& c,
                          float tracking) {
    text().draw(*cv_, face, S(size), S(x), S(y), t, c, S(tracking));
}

void SettingsPanel::changed() {
    out_->settingsChanged = true;
    lastChange_ = in_.time;
}

float SettingsPanel::enter(float delay) const {
    return easeOut((float)((in_.time - openTime_ - delay) / 0.45));
}

void SettingsPanel::resetInteraction() {
    active_ = 0;
    hot_ = 0;
    focus_ = 0;
    tipId_ = 0;
}

bool SettingsPanel::dragArea(float x, float y) const {
    if (y < 0 || y > S(68.f)) return false;
    for (const Rc& r : headerHits_)
        if (r.contains(x, y)) return false;
    return true;
}

void SettingsPanel::computeAccent() {
    float h, s, v;
    const RGBA f = st_->style.fill;
    rgbToHsv(f, h, s, v);
    if (s < 0.08f || v < 0.15f) {
        // neutral colours -> elegant silver/ice accent
        accent_ = RGBA{0.90f, 0.92f, 1.0f, 1};
        accentDeep_ = RGBA{0.62f, 0.66f, 0.80f, 1};
        accentText_ = RGBA{0.90f, 0.92f, 1.0f, 1};
        accentAlt_ = RGBA{0.55f, 0.62f, 1.0f, 1};
        return;
    }
    accent_ = hsvToRgb(h, std::min(0.62f, std::max(0.40f, s * 1.9f)), 1.0f);
    accentDeep_ = hsvToRgb(h - 0.025f, std::min(0.86f, std::max(0.64f, s * 3.0f)), 0.95f);
    accentText_ = hsvToRgb(h, std::min(0.42f, std::max(0.26f, s * 1.4f)), 1.0f);
    accentAlt_ = hsvToRgb(h + 0.11f, std::min(0.75f, std::max(0.50f, s * 2.4f)), 1.0f);
}

void SettingsPanel::ripple(uint32_t id, const Rc& r, float radius, const RGBA& c) {
    auto it = ripples_.find(id);
    if (it == ripples_.end()) return;
    const Ripple rp = it->second;
    const float t = (float)(in_.time - rp.t0);
    const float dur = 0.65f;
    if (t < 0.f || t > dur) return;
    animating_ = true;
    const float p = t / dur;
    const float maxR = std::hypot(std::max(rp.x - r.x, r.r() - rp.x), std::max(rp.y - r.y, r.b() - rp.y));
    const float rr = maxR * easeOut(std::min(1.f, p * 1.7f));
    const float a = c.a * (1.f - p) * (1.f - p);
    const float aa = std::max(1.f, S(1.f));
    cv_->paintRoundRect(r, radius, [&](float x, float y, float* o) {
        const float d = std::hypot(x - rp.x, y - rp.y) - rr;
        o[0] = c.r;
        o[1] = c.g;
        o[2] = c.b;
        o[3] = a * clamp01(0.5f - d / aa);
    });
}

void SettingsPanel::tooltip(uint32_t id, const Rc& anchor, const std::string& t) {
    if (!hovered(anchor) || in_.mouseDown) {
        if (tipId_ == id) tipId_ = 0;
        return;
    }
    if (tipId_ != id) {
        tipId_ = id;
        tipStart_ = in_.time;
    }
    tipWanted_ = true;
    tipText_ = t;
    tipAnchor_ = anchor;
}

void SettingsPanel::drawTooltip() {
    if (!tipWanted_) {
        tipId_ = 0;
        return;
    }
    const float t = (float)((in_.time - tipStart_ - 0.40) / 0.14);
    if (t < 1.f) animating_ = true;
    if (t <= 0.f) return;
    const float a = smooth(t);
    Canvas& cv = *cv_;
    const float fs = S(11.5f);
    const float tw = text().measure(FONT_SEMIBOLD, fs, tipText_);
    Rc tip{tipAnchor_.cx() - tw * 0.5f - S(11.f), tipAnchor_.b() + S(8.f) - S(4.f) * (1.f - a), tw + S(22.f), S(28.f)};
    tip.x = std::min(tip.x, (float)cv.w - tip.w - S(10.f));
    tip.x = std::max(tip.x, S(10.f));
    if (tip.b() > (float)cv.h - S(6.f)) tip.y = tipAnchor_.y - S(8.f) - tip.h;  // flip above near the bottom
    const float ga = cv.globalAlpha;
    cv.globalAlpha = a;
    cv.shadow(tip, S(9.f), S(14.f), Bk(0.55f), S(4.f));
    cv.fillRoundRectGrad(tip, S(9.f), RGBA{0.17f, 0.16f, 0.21f, 0.97f}, RGBA{0.11f, 0.11f, 0.14f, 0.97f});
    cv.strokeRoundRectGrad(tip, S(9.f), px1(), W(0.20f), W(0.06f));
    text().drawIn(cv, FONT_SEMIBOLD, fs, tip, tipText_, W(0.92f), 1);
    cv.globalAlpha = ga;
}

template <class F>
void SettingsPanel::cachedImage(ImageCache& c, const char* tag, const Rc& r, const std::string& key, F&& paint) {
    const int x0 = (int)std::floor(r.x), y0 = (int)std::floor(r.y);
    const int x1 = (int)std::ceil(r.r()), y1 = (int)std::ceil(r.b());
    const int w = x1 - x0, h = y1 - y0;
    if (w <= 0 || h <= 0) return;
    char kb[96];
    std::snprintf(kb, sizeof(kb), "%s %d %d %.2f %.2f|", tag, w, h, r.x - x0, r.y - y0);
    const std::string full = kb + key;
    if (c.key != full || c.px.size() != (size_t)w * h) {
        c.key = full;
        c.w = w;
        c.h = h;
        c.px.assign((size_t)w * h, 0u);
        Canvas tmp;
        tmp.attach(c.px.data(), w, h, w);
        paint(tmp, Rc{r.x - x0, r.y - y0, r.w, r.h});
    }
    cv_->drawImage(c.px.data(), w, h, w, x0, y0);
}

// ============================================================ widgets

void SettingsPanel::card(const Rc& r, float radius) {
    if (cardsBaked_ && !baking_) return;  // already part of the cached background
    Canvas& cv = *cv_;
    const int c0 = cv.clipX0, c1 = cv.clipY0, c2 = cv.clipX1, c3 = cv.clipY1;
    if (baking_) cv.resetClip();
    struct Restore {
        Canvas& cv;
        bool on;
        int a, b, c, d;
        ~Restore() {
            if (on) cv.setClip(a, b, c, d);
        }
    } restore{cv, baking_, c0, c1, c2, c3};
    const float rad = S(radius);
    cv.shadow(r, rad, S(26.f), Bk(0.22f), S(10.f));
    cv.fillRoundRectGrad(r, rad, W(0.068f), W(0.026f));
    // specular rim: bright along the top edge, fading down the sides
    cv.paintRing(r, rad, px1(), [&](float x, float y, float* o) {
        const float ty = clamp01((y - r.y) / r.h);
        const float tx = std::fabs((x - r.x) / r.w - 0.35f);
        o[0] = o[1] = o[2] = 1.f;
        o[3] = 0.045f + 0.15f * (1.f - ty) * (1.f - ty) * (1.f - clamp01(tx * 1.2f) * 0.6f);
    });
}

void SettingsPanel::valuePill(float right, float y, const std::string& v) {
    const float fs = S(11.5f);
    const float vw = text().measure(FONT_SEMIBOLD, fs, v);
    const Rc pill{S(right) - vw - S(18.f), S(y), vw + S(18.f), S(21.f)};
    cv_->fillRoundRect(pill, S(7.f), alpha(accent_, 0.11f));
    cv_->strokeRoundRect(pill, S(7.f), px1(), alpha(accent_, 0.16f));
    text().drawIn(*cv_, FONT_SEMIBOLD, fs, pill, v, accentText_, 1);
}

void SettingsPanel::microLabel(float x, float y, const std::string& t) {
    label(x, y, t, 9.5f, FONT_BOLD, W(0.40f), 1.7f);
}

bool SettingsPanel::toggle(uint32_t id, const Rc& r, bool& v) {
    bool hov = false;
    const bool clicked = behave(id, r.inset(-S(4)), &hov);
    if (clicked) {
        v = !v;
        changed();
    }
    Canvas& cv = *cv_;
    const float k = spring(id, v ? 1.f : 0.f, 260.f, 20.f);  // knob with a little overshoot
    const float t = clamp01(k);
    const float hv = anim(id ^ 0x55u, hov ? 1.f : 0.f, 18.f);
    const float h = r.h;
    if (t > 0.01f) cv.shadow(r, h * 0.5f, S(14.f), alpha(accentDeep_, 0.45f * t), S(2.f));
    cv.fillRoundRect(r, h * 0.5f, Bk(0.32f));
    cv.fillRoundRect(r, h * 0.5f, W(0.06f + 0.05f * hv));
    if (t > 0.001f) {
        RGBA a0 = accentDeep_, a1 = accent_;
        a0.a *= t;
        a1.a *= t;
        cv.fillRoundRectGrad(r, h * 0.5f, a0, a1, false);
    }
    cv.strokeRoundRectGrad(r, h * 0.5f, px1(), mix(Bk(0.25f), W(0.30f), t), mix(W(0.10f), W(0.08f), t));
    const float kr = h * 0.5f - S(3.f);
    const float kx = r.x + h * 0.5f + k * (r.w - h);
    const float ky = r.cy();
    const Rc kb{kx - kr, ky - kr, kr * 2, kr * 2};
    cv.shadow(kb, kr, S(6.f), Bk(0.45f), S(1.5f));
    cv.fillRoundRectGrad(kb, kr, W(1.f), RGBA{0.86f, 0.86f, 0.90f, 1});
    cv.strokeRoundRect(kb, kr, px1(), Bk(0.08f));
    return clicked;
}

bool SettingsPanel::slider(uint32_t id, const Rc& r, float& v, float lo, float hi, float step) {
    bool hov = false, held = false;
    behave(id, r.inset(0, -S(4)), &hov, &held);
    bool ch = false;
    if (held) {
        const float t = clamp01((in_.mx - r.x) / r.w);
        float nv = lo + t * (hi - lo);
        if (step > 0) nv = std::round(nv / step) * step;
        nv = std::max(lo, std::min(hi, nv));
        if (nv != v) {
            v = nv;
            ch = true;
        }
    } else if (hov && in_.wheel != 0.f) {
        const float st = step > 0 ? step : (hi - lo) / 100.f;
        const float nv = std::max(lo, std::min(hi, v + st * (in_.wheel > 0 ? 1.f : -1.f)));
        if (nv != v) {
            v = nv;
            ch = true;
        }
    }
    if (ch) changed();
    Canvas& cv = *cv_;
    const float tv = clamp01((v - lo) / (hi - lo));
    float t = anim(id ^ 0x3Bu, tv, 24.f);  // glide when changed by wheel / reset / presets
    if (held) {
        t = tv;
        anim_[id ^ 0x3Bu] = tv;
    }
    const float cy = r.cy();
    const float th = S(6.f);
    const Rc track{r.x, cy - th * 0.5f, r.w, th};
    cv.fillRoundRect(track, th * 0.5f, Bk(0.34f));
    cv.strokeRoundRectGrad(track, th * 0.5f, px1(), Bk(0.30f), W(0.08f));
    const float tw = std::max(th, r.w * t);
    const Rc fill{r.x, track.y, tw, th};
    const float hv = anim(id ^ 0x77u, (hov || held) ? 1.f : 0.f, 18.f);
    cv.shadow(fill, th * 0.5f, S(10.f), alpha(accentDeep_, 0.35f + 0.25f * hv), 0.f);
    cv.fillRoundRectGrad(fill, th * 0.5f, accentDeep_, accent_, false);
    cv.fillRoundRect(Rc{fill.x + th * 0.5f, fill.y + px1() * 0.5f, std::max(0.f, fill.w - th), px1()}, 0.f, W(0.22f));
    const float dr = anim(id ^ 0x99u, held ? 1.f : 0.f, 20.f);
    const float kx = r.x + r.w * t;
    const float kr = S(8.f) + S(1.5f) * hv;
    const float halo = std::max(dr, hv * 0.6f);
    if (halo > 0.01f) cv.fillCircle(kx, cy, kr + S(7.f) * halo, alpha(accent_, 0.16f * std::max(dr, hv * 0.7f)));
    const Rc kb{kx - kr, cy - kr, kr * 2, kr * 2};
    cv.shadow(kb, kr, S(8.f), Bk(0.5f), S(2.f));
    cv.fillRoundRectGrad(kb, kr, W(1.f), RGBA{0.84f, 0.84f, 0.88f, 1});
    cv.strokeRoundRect(kb, kr, px1(), Bk(0.10f));
    cv.fillCircle(kx, cy, kr * 0.36f, mix(accentDeep_, accent_, 0.3f));
    return ch;
}

bool SettingsPanel::segmented(uint32_t id, const Rc& r, const std::vector<std::string>& items, int& sel,
                              float fontSize) {
    const int n = (int)items.size();
    if (n == 0) return false;
    Canvas& cv = *cv_;
    const float rad = S(11.f);
    cv.fillRoundRect(r, rad, Bk(0.28f));
    cv.strokeRoundRectGrad(r, rad, px1(), Bk(0.25f), W(0.07f));
    const float iw = (r.w - S(6.f)) / n;
    const float sx = spring(id, (float)sel, 240.f, 24.f);
    const Rc pill{r.x + S(3.f) + sx * iw, r.y + S(3.f), iw, r.h - S(6.f)};
    cv.shadow(pill, S(9.f), S(8.f), Bk(0.45f), S(2.f));
    cv.fillRoundRectGrad(pill, S(9.f), W(0.20f), W(0.11f));
    cv.strokeRoundRectGrad(pill, S(9.f), px1(), W(0.30f), W(0.05f));
    bool changedSel = false;
    for (int i = 0; i < n; ++i) {
        const Rc cell{r.x + S(3.f) + i * iw, r.y, iw, r.h};
        bool hov = false;
        if (behave(id + 1 + i, cell, &hov) && sel != i) {
            sel = i;
            changedSel = true;
            changed();
        }
        const float hv = anim((id + 1 + i) ^ 0x31u, hov ? 1.f : 0.f, 18.f);
        const float isSel = clamp01(1.f - std::fabs(sx - i));
        const RGBA col = W(0.52f + 0.18f * hv + 0.36f * isSel);
        text().drawIn(cv, isSel > 0.5f ? FONT_SEMIBOLD : FONT_MEDIUM, S(fontSize), cell, items[i], col, 1);
    }
    return changedSel;
}

bool SettingsPanel::button(uint32_t id, const Rc& r, const std::string& t, int style, int ic) {
    bool hov = false, held = false;
    const bool clicked = behave(id, r, &hov, &held);
    Canvas& cv = *cv_;
    const float hv = anim(id, hov ? 1.f : 0.f, 18.f);
    const float pr = anim(id ^ 0x5u, held ? 1.f : 0.f, 25.f);
    const float rad = S(12.f);
    RGBA txt = W(0.92f);
    if (style == 1) {  // primary
        cv.shadow(r, rad, S(16.f), alpha(accentDeep_, 0.40f + 0.25f * hv), S(4.f));
        cv.fillRoundRectGrad(r, rad, mix(accent_, kWhite, 0.12f * hv), mix(accentDeep_, kWhite, 0.08f * hv));
        cv.strokeRoundRectGrad(r, rad, px1(), W(0.50f), W(0.10f));
        txt = RGBA{0.07f, 0.05f, 0.09f, 0.94f};
    } else if (style == 2) {  // danger
        const RGBA red{1.f, 0.33f, 0.36f, 1};
        cv.fillRoundRect(r, rad, alpha(red, 0.12f + 0.12f * hv + 0.1f * pr));
        cv.strokeRoundRect(r, rad, px1(), alpha(red, 0.35f + 0.25f * hv));
        txt = RGBA{1.f, 0.72f, 0.74f, 1};
    } else {  // glass
        cv.shadow(r, rad, S(16.f), Bk(0.25f), S(5.f));
        cv.fillRoundRectGrad(r, rad, W(0.10f + 0.05f * hv - 0.03f * pr), W(0.045f + 0.035f * hv));
        cv.strokeRoundRectGrad(r, rad, px1(), W(0.22f + 0.08f * hv), W(0.05f));
    }
    ripple(id, r, rad, style == 1 ? W(0.45f) : W(0.16f));
    const float fs = S(13.f);
    const float tw = text().measure(FONT_SEMIBOLD, fs, t);
    float x = r.cx() - tw * 0.5f;
    if (ic >= 0) {
        const float isz = S(14.f);
        x += (isz + S(8.f)) * 0.5f;
        icon(ic, x - S(8.f) - isz * 0.5f, r.cy(), isz, txt);
    }
    text().draw(cv, FONT_SEMIBOLD, fs, x, r.cy() + text().capHeight(FONT_SEMIBOLD, fs) * 0.5f, t, txt);
    return clicked;
}

bool SettingsPanel::iconButton(uint32_t id, const Rc& r, int ic, const std::string& tip) {
    bool hov = false, held = false;
    const bool clicked = behave(id, r, &hov, &held);
    Canvas& cv = *cv_;
    const float hv = anim(id, hov ? 1.f : 0.f, 18.f);
    if (hv > 0.01f) {
        const RGBA bg = ic == IC_POWER ? RGBA{1.f, 0.35f, 0.38f, 0.20f * hv} : W(0.09f * hv + (held ? 0.04f : 0.f));
        cv.fillRoundRect(r, S(11.f), bg);
        cv.strokeRoundRect(r, S(11.f), px1(), W(0.08f * hv));
    }
    ripple(id, r, S(11.f), W(0.18f));
    icon(ic, r.cx(), r.cy(), S(15.f), W(0.62f + 0.33f * hv));
    if (!tip.empty()) tooltip(id, r, tip);
    return clicked;
}

void SettingsPanel::keycap(const Rc& r, const std::string& t, bool glowing) {
    Canvas& cv = *cv_;
    const float rad = S(9.f);
    if (glowing) {
        const float pulse = 0.5f + 0.5f * std::sin((float)in_.time * 5.f);
        cv.shadow(r, rad, S(18.f), alpha(accent_, 0.35f + 0.35f * pulse), 0.f, S(1.f));
    }
    cv.fillRoundRect(r.offset(0, S(2.5f)), rad, Bk(0.55f));
    cv.fillRoundRectGrad(r, rad, W(0.22f), W(0.10f));
    cv.strokeRoundRectGrad(r, rad, px1(), W(0.34f), W(0.07f));
    text().drawIn(cv, FONT_SEMIBOLD, S(12.5f), r.offset(0, -S(0.5f)), t, glowing ? accentText_ : W(0.94f), 1);
}

void SettingsPanel::iconTile(int which, const Rc& r, int palette, float glow) {
    Canvas& cv = *cv_;
    const float rad = r.w * 0.30f;
    const RGBA top = kTileTop[palette], bot = kTileBot[palette];
    if (glow > 0.01f) cv.shadow(r, rad, S(14.f), alpha(bot, 0.55f * glow), S(2.f));
    cv.shadow(r, rad, S(6.f), Bk(0.35f), S(2.f));
    cv.fillRoundRectGrad(r, rad, top, bot);
    cv.paintRing(r, rad, px1(), [&](float, float y, float* o) {
        const float ty = clamp01((y - r.y) / r.h);
        o[0] = o[1] = o[2] = 1.f;
        o[3] = 0.55f * (1.f - ty) * (1.f - ty) + 0.04f;
    });
    icon(which, r.cx(), r.cy(), r.w * 0.56f, W(0.98f));
}

void SettingsPanel::icon(int which, float cx, float cy, float size, const RGBA& c) {
    const float u = size / 16.f;  // icon grid is 16x16
    const float lw = std::max(1.2f, 1.6f * u);
    Canvas& cv = *cv_;
    switch (which) {
        case IC_COLORS: {
            const float r = 3.6f * u;
            cv.strokeCircle(cx, cy - 2.4f * u, r, lw, c);
            cv.strokeCircle(cx - 2.6f * u, cy + 2.0f * u, r, lw, c);
            cv.strokeCircle(cx + 2.6f * u, cy + 2.0f * u, r, lw, c);
            break;
        }
        case IC_SHAPE: {
            const float a = 7.2f * u, b = 3.6f * u;
            const float pts[8] = {cx, cy - a, cx + b, cy, cx, cy + a, cx - b, cy};
            cv.fillPoly(pts, 4, alpha(c, 0.30f));
            for (int i = 0; i < 4; ++i) {
                const int j = (i + 1) % 4;
                cv.line(pts[2 * i], pts[2 * i + 1], pts[2 * j], pts[2 * j + 1], lw, c);
            }
            break;
        }
        case IC_MOTION: {
            cv.arc(cx, cy, 5.6f * u, -kPi * 0.95f, kPi * 0.55f, lw, c);
            const float ex = cx + std::cos(kPi * 0.55f) * 5.6f * u, ey = cy + std::sin(kPi * 0.55f) * 5.6f * u;
            const float tri[6] = {ex - 3.4f * u, ey - 0.6f * u, ex + 1.8f * u, ey - 3.0f * u, ex + 1.2f * u, ey + 2.6f * u};
            cv.fillPoly(tri, 3, c);
            break;
        }
        case IC_EFFECTS: {
            auto star = [&](float x, float y, float R, float r) {
                float pts[16];
                for (int i = 0; i < 8; ++i) {
                    const float a = -kPi / 2 + i * kPi / 4;
                    const float rr = (i % 2 == 0) ? R : r;
                    pts[2 * i] = x + std::cos(a) * rr;
                    pts[2 * i + 1] = y + std::sin(a) * rr;
                }
                for (int i = 0; i < 8; ++i) {
                    const int j = (i + 1) % 8;
                    const float tri[6] = {x, y, pts[2 * i], pts[2 * i + 1], pts[2 * j], pts[2 * j + 1]};
                    cv.fillPoly(tri, 3, c);
                }
            };
            star(cx - 1.2f * u, cy + 0.8f * u, 6.4f * u, 1.7f * u);
            star(cx + 4.6f * u, cy - 4.4f * u, 2.6f * u, 0.8f * u);
            break;
        }
        case IC_SETTINGS: {
            const float x0 = cx - 6.f * u, x1 = cx + 6.f * u;
            const float ys[3] = {cy - 4.5f * u, cy, cy + 4.5f * u};
            const float ks[3] = {cx + 2.5f * u, cx - 2.5f * u, cx + 0.8f * u};
            for (int i = 0; i < 3; ++i) {
                cv.line(x0, ys[i], x1, ys[i], lw, alpha(c, 0.75f));
                cv.fillCircle(ks[i], ys[i], 2.2f * u, c);
            }
            break;
        }
        case IC_CLOSE: {
            const float d = 4.6f * u;
            cv.line(cx - d, cy - d, cx + d, cy + d, lw, c);
            cv.line(cx + d, cy - d, cx - d, cy + d, lw, c);
            break;
        }
        case IC_POWER: {
            cv.arc(cx, cy + 0.6f * u, 5.6f * u, -kPi * 0.5f + 0.62f, kPi * 1.5f - 0.62f, lw, c);
            cv.line(cx, cy - 6.4f * u, cx, cy - 0.6f * u, lw, c);
            break;
        }
        case IC_RESET: {
            cv.arc(cx, cy, 5.4f * u, -kPi * 0.45f, kPi * 1.25f, lw, c);
            const float ex = cx + std::cos(-kPi * 0.45f) * 5.4f * u, ey = cy + std::sin(-kPi * 0.45f) * 5.4f * u;
            const float tri[6] = {ex + 3.2f * u, ey - 0.4f * u, ex - 1.6f * u, ey - 3.2f * u, ex - 1.0f * u, ey + 2.6f * u};
            cv.fillPoly(tri, 3, c);
            break;
        }
        case IC_COPY: {
            cv.strokeRoundRect(Rc{cx - 3.5f * u, cy - 3.5f * u, 9.f * u, 9.f * u}, 2.f * u, lw, c);
            cv.strokeRoundRect(Rc{cx - 6.f * u, cy - 6.f * u, 9.f * u, 9.f * u}, 2.f * u, lw, alpha(c, 0.6f));
            break;
        }
        case IC_CHECK: {
            cv.line(cx - 5.f * u, cy, cx - 1.5f * u, cy + 3.8f * u, lw * 1.15f, c);
            cv.line(cx - 1.5f * u, cy + 3.8f * u, cx + 5.5f * u, cy - 4.2f * u, lw * 1.15f, c);
            break;
        }
        case IC_TARGET: {
            cv.strokeCircle(cx, cy, 5.5f * u, lw, c);
            cv.fillCircle(cx, cy, 1.6f * u, c);
            break;
        }
        default: break;
    }
}

void SettingsPanel::sliderRow(uint32_t id, float x, float y, float w, const std::string& name,
                              const std::string& value, float& v, float lo, float hi, float step) {
    label(x, y + 15.f, name, 13.f, FONT_MEDIUM, W(0.88f));
    valuePill(x + w, y + 1.f, value);
    slider(id, R(x, y + 27.f, w, 22.f), v, lo, hi, step);
}

void SettingsPanel::toggleRow(uint32_t id, float x, float y, float w, const std::string& name,
                              const std::string& desc, bool& v) {
    label(x, y + 17.f, name, 13.f, FONT_MEDIUM, W(0.90f));
    if (!desc.empty()) label(x, y + 35.f, desc, 11.5f, FONT_REGULAR, W(0.46f));
    toggle(id, R(x + w - 44.f, y + 10.f, 44.f, 24.f), v);
}

// ============================================================ frame

void SettingsPanel::frame(Canvas& cv, float scale, const UIInput& in, Settings& st, UIActions& out,
                          const AppStatus& status) {
    text().init();
    cv_ = &cv;
    s_ = scale;
    in_ = in;
    out_ = &out;
    st_ = &st;
    status_ = &status;
    out.cursor = CURSOR_ARROW;
    headerHits_.clear();
    tipWanted_ = false;
    computeAccent();

    // Full redraw vs cheap preview-only redraw: anything that could change pixels
    // outside the preview card forces a full frame.
    const std::string snap = serializeSettings(st);
    const bool inputChanged = in.mx != lastMx_ || in.my != lastMy_ || in.mouseDown != lastDown_ || in.mousePressed ||
                              in.mouseReleased || in.wheel != 0.f || !in.typed.empty() || in.kBack || in.kDelete ||
                              in.kEnter || in.kEscape || in.kLeft || in.kRight || in.kHome || in.kEnd ||
                              in.kSelectAll || in.kPaste || in.kCopy;
    const bool full = fullDirty_ || inputChanged || animating_ || scale != lastScale_ || snap != lastSettings_ ||
                      status.capturing != 0 || st.rainbow;
    lastMx_ = in.mx;
    lastMy_ = in.my;
    lastDown_ = in.mouseDown;
    lastScale_ = scale;
    fullDirty_ = false;
    animating_ = false;
    previewAnimating_ = false;
    hot_ = 0;

    // static glass layer (tint, aurora light, grain, hairlines) is cached; when nothing
    // is sliding in, the cards and panel shadows are baked on top of it as well
    buildBackground();
    const bool atRest = in.time - openTime_ > 0.75 && in.time - pageSwitchTime_ > 0.3 && st.page == prevPage_;
    cardsBaked_ = false;
    if (atRest) {
        bakeStatic();
        cardsBaked_ = true;
    }
    const std::vector<uint32_t>& base = cardsBaked_ ? bakeCache_ : bgCache_;
    cv.globalAlpha = 1.f;
    const Rc pv = R(636.f, 84.f, 308.f, 292.f);
    if (full) {
        cv.resetClip();
        for (int y = 0; y < cv.h; ++y)
            std::memcpy(cv.px + (size_t)y * cv.stride, base.data() + (size_t)y * cv.w, (size_t)cv.w * 4);
        dirty_ = Rc{0, 0, (float)cv.w, (float)cv.h};
    } else {
        cv.setClip(pv);
        for (int y = cv.clipY0; y < cv.clipY1; ++y)
            std::memcpy(cv.px + (size_t)y * cv.stride + cv.clipX0, base.data() + (size_t)y * cv.w + cv.clipX0,
                        (size_t)(cv.clipX1 - cv.clipX0) * 4);
        dirty_ = Rc{(float)cv.clipX0, (float)cv.clipY0, (float)(cv.clipX1 - cv.clipX0), (float)(cv.clipY1 - cv.clipY0)};
    }
    const int fx0 = cv.clipX0, fy0 = cv.clipY0, fx1 = cv.clipX1, fy1 = cv.clipY1;
    auto restoreClip = [&]() { cv.setClip(fx0, fy0, fx1, fy1); };
    if (in.time - openTime_ < 0.8) animating_ = true;

    cv.globalAlpha = enter(0.f);
    drawHeader();
    restoreClip();
    cv.globalAlpha = enter(0.05f);
    drawSidebar();
    restoreClip();

    // ---- page content: staggered entrance + soft fade/slide between pages
    if (st.page != prevPage_) {
        pageSwitchTime_ = in.time;
        prevPage_ = st.page;
        focus_ = 0;
    }
    const float pt = easeOut((float)((in.time - pageSwitchTime_) / 0.26));
    if (pt < 1.f) animating_ = true;
    const float ce = enter(0.10f);
    const float x = 244.f, w = 376.f;
    const float yoff = (1.f - pt) * 12.f + (1.f - ce) * 16.f;
    cv.globalAlpha = (0.2f + 0.8f * pt) * ce;
    label(x, 110.f + yoff, kPageNames[st.page], 24.f, FONT_SEMIBOLD, W(0.97f), -0.4f);
    label(x, 133.f + yoff, kPageDesc[st.page], 12.5f, FONT_REGULAR, W(0.50f));
    const float cy = 152.f + yoff;
    switch (st.page) {
        case 0: pageColors(x, cy, w); break;
        case 1: pageShape(x, cy, w); break;
        case 2: pageMotion(x, cy, w); break;
        case 3: pageEffects(x, cy, w); break;
        default: pageSettings(x, cy, w); break;
    }
    restoreClip();

    cv.globalAlpha = enter(0.15f);
    drawPreview();
    restoreClip();
    cv.globalAlpha = enter(0.20f);
    drawThemes();
    restoreClip();
    cv.globalAlpha = 1.f;
    drawTooltip();
    cv.resetClip();

    // clicking anywhere else cancels a pending key capture
    if (status.capturing != 0 && in.mousePressed && !bindHovered_) out.cancelBind = true;
    bindHovered_ = false;
    if (active_ != 0 && !in.mouseDown) active_ = 0;
    if (in.mousePressed && hot_ == 0) focus_ = 0;
    if (focus_ != 0) animating_ = true;  // caret blink
    lastSettings_ = serializeSettings(st);
}

// ============================================================ sections

void SettingsPanel::buildBackground() {
    Canvas& cv = *cv_;
    char keyBuf[160];
    std::snprintf(keyBuf, sizeof(keyBuf), "%d %d %.3f %d %d %.3f %.3f %.3f", cv.w, cv.h, s_, status_->glassLevel,
                  (int)status_->glassBackdrop, accent_.r, accent_.g, accent_.b);
    if (bgKey_ == keyBuf && bgCache_.size() == (size_t)cv.w * cv.h) return;
    bgKey_ = keyBuf;
    bgCache_.assign((size_t)cv.w * cv.h, 0u);
    Canvas bg;
    bg.attach(bgCache_.data(), cv.w, cv.h, cv.w);
    const Rc win{0, 0, S(kWidth), S(kHeight)};
    const float rad = S(8.f);
    const int level = status_->glassBackdrop ? status_->glassLevel : 0;
    float a0 = 0.985f, a1 = 0.995f;
    if (level >= 2) {
        a0 = 0.56f;
        a1 = 0.72f;
    } else if (level == 1) {
        a0 = 0.74f;
        a1 = 0.86f;
    }
    // tint: diagonal gradient, slightly violet at the top-left
    const RGBA c0{0.085f, 0.078f, 0.125f, a0}, c1{0.035f, 0.035f, 0.055f, a1};
    bg.paintRoundRect(win, rad, [&](float x, float y, float* o) {
        const float t = clamp01((x / win.w) * 0.45f + (y / win.h) * 0.55f);
        const RGBA c = mix(c0, c1, t);
        o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = c.a;
    });
    // aurora light from the accent colour
    bg.pushClip(win);
    bg.glowBlob(S(kWidth * 0.80f), S(-70.f), S(560.f), S(300.f), alpha(accent_, 0.19f));
    bg.glowBlob(S(kWidth * 0.40f), S(-120.f), S(360.f), S(200.f), alpha(accentAlt_, 0.08f));
    bg.glowBlob(S(110.f), S(kHeight + 90.f), S(520.f), S(260.f), alpha(accentAlt_, 0.12f));
    bg.glowBlob(S(kWidth * 0.55f), S(kHeight * 0.62f), S(440.f), S(300.f), RGBA{0.42f, 0.32f, 1.0f, 0.045f});
    bg.popClip();
    // frosted grain
    bg.paintRoundRect(win, rad, [&](float x, float y, float* o) {
        const float n = hash01((int)x, (int)y) - 0.5f;
        const float v = n > 0 ? 1.f : 0.f;
        o[0] = o[1] = o[2] = v;
        o[3] = std::fabs(n) * 0.055f;
    });
    // hairlines (fade out towards their ends)
    bg.paintRoundRect(Rc{S(16.f), S(68.f), S(kWidth - 32.f), px1()}, 0.f, [&](float x, float, float* o) {
        const float t = (x - S(16.f)) / S(kWidth - 32.f);
        o[0] = o[1] = o[2] = 1.f;
        o[3] = 0.10f * std::sin(clamp01(t) * kPi);
    });
    bg.paintRoundRect(Rc{S(228.f), S(84.f), px1(), S(kHeight - 100.f)}, 0.f, [&](float, float y, float* o) {
        const float t = (y - S(84.f)) / S(kHeight - 100.f);
        o[0] = o[1] = o[2] = 1.f;
        o[3] = 0.08f * std::sin(clamp01(t) * kPi);
    });
    // top rim light + window edge
    bg.paintRoundRect(Rc{rad, px1(), win.w - 2 * rad, px1()}, 0.f, [&](float x, float, float* o) {
        const float t = x / win.w;
        const float s = std::sin(clamp01(t) * kPi);
        o[0] = o[1] = o[2] = 1.f;
        o[3] = 0.28f * s * s;
    });
    bg.strokeRoundRectGrad(win, rad, px1(), W(0.16f), W(0.05f));
}

void SettingsPanel::bakeStatic() {
    Canvas& cv = *cv_;
    const std::string key = bgKey_ + " page" + std::to_string(st_->page);
    if (bakeKey_ == key && bakeCache_.size() == (size_t)cv.w * cv.h) return;
    bakeKey_ = key;
    bakeCache_ = bgCache_;
    Canvas bk;
    bk.attach(bakeCache_.data(), cv.w, cv.h, cv.w);
    bk.setClip(0, 0, 0, 0);  // only card()/panel shadows draw (they lift the clip while baking)
    // run the layout with neutral input so no state changes
    Canvas* savedCv = cv_;
    const UIInput savedIn = in_;
    const bool savedAnim = animating_, savedPrev = previewAnimating_;
    const uint32_t savedTip = tipId_;
    const double savedTipStart = tipStart_;
    const bool savedTipWanted = tipWanted_;
    const float savedAngle = previewAngle_;
    UIActions dummy;
    UIActions* savedOut = out_;
    in_ = UIInput();
    in_.time = savedIn.time;
    in_.dt = 0.f;
    out_ = &dummy;
    cv_ = &bk;
    baking_ = true;
    drawSidebar();
    const float x = 244.f, w = 376.f, cy = 152.f;
    switch (st_->page) {
        case 0: pageColors(x, cy, w); break;
        case 1: pageShape(x, cy, w); break;
        case 2: pageMotion(x, cy, w); break;
        case 3: pageEffects(x, cy, w); break;
        default: pageSettings(x, cy, w); break;
    }
    drawPreview();
    baking_ = false;
    cv_ = savedCv;
    in_ = savedIn;
    out_ = savedOut;
    animating_ = savedAnim;
    previewAnimating_ = savedPrev;
    tipId_ = savedTip;
    tipStart_ = savedTipStart;
    tipWanted_ = savedTipWanted;
    previewAngle_ = savedAngle;
}

void SettingsPanel::drawHeader() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    // logo tile with the real crosshair
    const Rc tile = R(20.f, 15.f, 38.f, 38.f);
    cv.shadow(tile, S(11.f), S(18.f), alpha(accentDeep_, 0.35f), S(3.f));
    cv.shadow(tile, S(11.f), S(8.f), Bk(0.5f), S(2.f));
    cv.paintRoundRect(tile, S(11.f), [&](float x, float y, float* o) {
        const float dx = (x - tile.cx()) / tile.w, dy = (y - tile.cy()) / tile.h;
        const float g = std::exp(-(dx * dx + dy * dy) * 6.f);
        const RGBA base = mix(RGBA{0.17f, 0.16f, 0.22f, 1}, RGBA{0.05f, 0.05f, 0.07f, 1}, clamp01((y - tile.y) / tile.h));
        const RGBA c = mix(base, accentDeep_, 0.22f * g);
        o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1.f;
    });
    cv.strokeRoundRectGrad(tile, S(11.f), px1(), W(0.30f), W(0.05f));
    {
        CrosshairStyle ls = st.style;
        ls.scale = 0.5f * s_;
        ls.shadow = 0.f;
        ls.opacity = cv.globalAlpha;  // the renderer writes directly: honour fades
        logoRenderer_.prepare(ls);
        cv.pushClip(tile.inset(S(1.f)));
        logoRenderer_.render(cv.px, cv.w, cv.h, cv.stride, std::round(tile.cx()), std::round(tile.cy()), -0.3175f, ls,
                             cv.clipX0, cv.clipY0, cv.clipX1, cv.clipY1);
        cv.popClip();
    }
    const float ww = text().drawGradient(cv, FONT_BOLD, S(16.f), S(70.f), S(34.f), "VORTEX", W(0.98f),
                                         mix(accent_, kWhite, 0.25f), S(4.f));
    {
        const Rc ver{S(70.f) + ww + S(10.f), S(21.f), S(34.f), S(16.f)};
        cv.fillRoundRect(ver, S(5.f), W(0.08f));
        cv.strokeRoundRect(ver, S(5.f), px1(), W(0.10f));
        text().drawIn(cv, FONT_BOLD, S(8.5f), ver, "v1.1", W(0.60f), 1, S(0.4f));
    }
    label(70.f, 51.f, "CROSSHAIR STUDIO", 9.5f, FONT_SEMIBOLD, W(0.40f), 2.2f);

    // status pill: crosshair live / off
    const Rc closeR = R(kWidth - 16.f - 36.f, 16.f, 36.f, 36.f);
    const Rc quitR = R(kWidth - 16.f - 36.f - 8.f - 36.f, 16.f, 36.f, 36.f);
    const Rc pill = R(kWidth - 16.f - 36.f - 8.f - 36.f - 12.f - 172.f, 16.f, 172.f, 36.f);
    headerHits_.push_back(pill);
    headerHits_.push_back(quitR);
    headerHits_.push_back(closeR);
    bool hov = false;
    if (behave(ID("enable-pill"), pill, &hov)) {
        st.enabled = !st.enabled;
        changed();
    }
    const float onK = spring(ID("enable-anim"), st.enabled ? 1.f : 0.f, 260.f, 20.f);
    const float on = clamp01(onK);
    const float hv = anim(ID("enable-hov"), hov ? 1.f : 0.f, 18.f);
    cv.shadow(pill, pill.h * 0.5f, S(24.f), Bk(0.25f), S(4.f));
    cv.fillRoundRectGrad(pill, pill.h * 0.5f, W(0.10f + 0.04f * hv), W(0.045f + 0.03f * hv));
    cv.strokeRoundRectGrad(pill, pill.h * 0.5f, px1(), W(0.20f + 0.06f * hv), W(0.05f));
    ripple(ID("enable-pill"), pill, pill.h * 0.5f, W(0.14f));
    const float dx = pill.x + S(17.f), dy = pill.cy();
    const RGBA green{0.36f, 1.f, 0.62f, 1}, grey = W(0.35f);
    const RGBA dc = mix(grey, green, on);
    if (on > 0.01f) {
        cv.fillCircle(dx, dy, S(8.f), alpha(green, 0.10f * on));
        cv.fillCircle(dx, dy, S(5.5f), alpha(green, 0.18f * on));
    }
    cv.fillCircle(dx, dy, S(3.5f), dc);
    text().drawIn(cv, FONT_SEMIBOLD, S(12.5f), Rc{pill.x + S(30.f), pill.y, S(92.f), pill.h},
                  st.enabled ? "Crosshair live" : "Crosshair off", W(0.90f), 0);
    const Rc sw{pill.r() - S(10.f) - S(38.f), pill.cy() - S(11.f), S(38.f), S(22.f)};
    cv.fillRoundRect(sw, sw.h * 0.5f, Bk(0.30f));
    cv.fillRoundRect(sw, sw.h * 0.5f, W(0.06f));
    if (on > 0.001f) {
        RGBA a0 = accentDeep_, a1 = accent_;
        a0.a *= on;
        a1.a *= on;
        cv.fillRoundRectGrad(sw, sw.h * 0.5f, a0, a1, false);
    }
    const float kr = sw.h * 0.5f - S(2.5f);
    const Rc kb{sw.x + sw.h * 0.5f + onK * (sw.w - sw.h) - kr, sw.cy() - kr, kr * 2, kr * 2};
    cv.shadow(kb, kr, S(5.f), Bk(0.45f), S(1.f));
    cv.fillRoundRectGrad(kb, kr, W(1.f), RGBA{0.86f, 0.86f, 0.9f, 1});

    // quit (two-step confirm) and hide buttons
    const bool armed = in_.time - armedAt_ < 3.0;
    if (armed) {
        animating_ = true;
        const float a = 0.5f + 0.5f * std::sin((float)in_.time * 8.f);
        cv.fillRoundRect(quitR, S(11.f), RGBA{1.f, 0.3f, 0.34f, 0.22f + 0.2f * a});
        const std::string q = "Click again to quit";
        const float tw = text().measure(FONT_SEMIBOLD, S(11.5f), q);
        const Rc tip{quitR.cx() - tw * 0.5f - S(11.f), quitR.b() + S(8.f), tw + S(22.f), S(28.f)};
        cv.shadow(tip, S(9.f), S(12.f), Bk(0.5f), S(3.f));
        cv.fillRoundRect(tip, S(9.f), RGBA{0.18f, 0.06f, 0.08f, 0.97f});
        cv.strokeRoundRect(tip, S(9.f), px1(), RGBA{1.f, 0.4f, 0.45f, 0.55f});
        text().drawIn(cv, FONT_SEMIBOLD, S(11.5f), tip, q, RGBA{1.f, 0.82f, 0.84f, 1.f}, 1);
    }
    if (iconButton(ID("quit"), quitR, IC_POWER, armed ? std::string() : std::string("Quit Vortex"))) {
        if (armed)
            out_->quit = true;
        else
            armedAt_ = in_.time;
    }
    if (iconButton(ID("close"), closeR, IC_CLOSE, "Hide menu \xC2\xB7 " + keyName(st.menuKey))) out_->hideMenu = true;
}

void SettingsPanel::drawSidebar() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const float x = 16.f, w = 198.f;
    microLabel(x + 6.f, 101.f, "CUSTOMIZE");
    const int icons[5] = {IC_COLORS, IC_SHAPE, IC_MOTION, IC_EFFECTS, IC_SETTINGS};
    const float y0 = 112.f, ih = 46.f, gap = 4.f;
    const float selY = spring(ID("navsel"), y0 + st.page * (ih + gap), 210.f, 23.f);
    // selection pill
    const Rc sel = R(x, selY, w, ih);
    cv.shadow(sel, S(13.f), S(18.f), Bk(0.32f), S(4.f));
    cv.fillRoundRectGrad(sel, S(13.f), W(0.12f), W(0.055f));
    cv.paintRing(sel, S(13.f), px1(), [&](float px, float py, float* o) {
        const float ty = clamp01((py - sel.y) / sel.h), tx = clamp01((px - sel.x) / sel.w);
        o[0] = o[1] = o[2] = 1.f;
        o[3] = 0.05f + 0.20f * (1.f - ty) * (1.f - tx * 0.5f);
    });
    for (int i = 0; i < 5; ++i) {
        const float y = y0 + i * (ih + gap);
        const Rc r = R(x, y, w, ih);
        bool hov = false;
        if (behave(ID("nav", i), r, &hov) && st.page != i) {
            st.page = i;
            out_->settingsChanged = true;
        }
        const float hv = anim(ID("navh", i), hov ? 1.f : 0.f, 18.f);
        const float isSel = clamp01(1.f - std::fabs(selY - y) / (ih + gap));
        if (hv > 0.01f && st.page != i) cv.fillRoundRect(r, S(13.f), W(0.045f * hv));
        ripple(ID("nav", i), r, S(13.f), W(0.10f));
        iconTile(icons[i], R(x + 9.f, y + 8.f, 30.f, 30.f), i, isSel);
        text().drawIn(cv, isSel > 0.5f ? FONT_SEMIBOLD : FONT_MEDIUM, S(13.5f), Rc{S(x + 50.f), r.y, S(100.f), r.h},
                      kPageNames[i], W(0.62f + 0.14f * hv + 0.32f * isSel), 0);
        // live value hint on the right
        const Rc hint{S(x + w - 12.f - 70.f), r.y, S(70.f), r.h};
        const RGBA hc = W(0.34f + 0.16f * isSel);
        switch (i) {
            case 0: {
                const RGBA dots[3] = {st.style.glowCol, st.style.line, st.style.fill};
                for (int k = 0; k < 3; ++k) {
                    const float cxd = hint.r() - S(5.f) - k * S(9.f);
                    cv.fillCircle(cxd, r.cy(), S(4.6f), Bk(0.50f));
                    cv.fillCircle(cxd, r.cy(), S(3.5f), RGBA{dots[k].r, dots[k].g, dots[k].b, 1.f});
                }
                break;
            }
            case 1: text().drawIn(cv, FONT_MEDIUM, S(11.f), hint, fmtInt(st.style.scale * 100.f, "%"), hc, 2); break;
            case 2:
                text().drawIn(cv, FONT_MEDIUM, S(11.f), hint,
                              st.spin ? fmtInt(st.spinSpeed, "\xC2\xB0/s") : std::string("Off"), hc, 2);
                break;
            case 3: text().drawIn(cv, FONT_MEDIUM, S(11.f), hint, fmtInt(st.style.glow * 100.f, "%"), hc, 2); break;
            default:
                text().drawIn(cv, FONT_MEDIUM, S(11.f), hint, st.position == POS_CURSOR ? "Cursor" : "Center", hc, 2);
                break;
        }
    }

    // hotkey card with a live "saved" indicator
    const float cy = kHeight - 16.f - 116.f;
    card(R(x, cy, w, 116.f), 16.f);
    microLabel(x + 16.f, cy + 26.f, "MENU KEY");
    const float sinceSave = (float)(in_.time - lastChange_);
    if (sinceSave < 2.4f) {
        animating_ = true;
        const float a = clamp01(sinceSave / 0.15f) * clamp01((2.4f - sinceSave) / 0.5f);
        const float ga = cv.globalAlpha;
        cv.globalAlpha = ga * a;
        const RGBA green{0.40f, 1.f, 0.66f, 1};
        icon(IC_CHECK, S(x + w - 58.f), S(cy + 22.5f), S(11.f), green);
        label(x + w - 50.f, cy + 26.f, "Saved", 11.f, FONT_SEMIBOLD, alpha(green, 0.9f));
        cv.globalAlpha = ga;
    }
    const std::string kn = keyName(st.menuKey);
    const float kw = std::max(S(92.f), text().measure(FONT_SEMIBOLD, S(12.5f), kn) + S(30.f));
    keycap(Rc{S(x + 16.f), S(cy + 40.f), kw, S(34.f)}, kn, false);
    label(x + 16.f, cy + 98.f, "Tap to show or hide", 11.5f, FONT_REGULAR, W(0.45f));
}

void SettingsPanel::paintPreviewBackground(Canvas& cv, const Rc& r, int bg) {
    const float rad = S(18.f);
    switch (bg) {
        case 1: {  // dusk scene: sky + ground
            const float horizon = r.y + r.h * 0.62f;
            cv.paintRoundRect(r, rad, [&](float x, float y, float* o) {
                (void)x;
                if (y < horizon) {
                    const float t = clamp01((y - r.y) / (horizon - r.y));
                    const RGBA top{0.09f, 0.12f, 0.24f, 1}, mid{0.36f, 0.33f, 0.52f, 1}, low{0.93f, 0.55f, 0.42f, 1};
                    const RGBA c = t < 0.7f ? mix(top, mid, t / 0.7f) : mix(mid, low, (t - 0.7f) / 0.3f);
                    o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1;
                } else {
                    const float t = clamp01((y - horizon) / (r.b() - horizon));
                    const RGBA c = mix(RGBA{0.20f, 0.15f, 0.16f, 1}, RGBA{0.07f, 0.06f, 0.07f, 1}, smooth(t));
                    o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1;
                }
            });
            cv.pushClip(r);
            cv.glowBlob(r.x + r.w * 0.68f, horizon, r.w * 0.35f, r.h * 0.12f, RGBA{1.f, 0.72f, 0.5f, 0.45f});
            cv.popClip();
            break;
        }
        case 2:  // bright scene
            cv.fillRoundRectGrad(r, rad, RGBA{0.93f, 0.94f, 0.96f, 1}, RGBA{0.78f, 0.81f, 0.86f, 1});
            break;
        case 3: {  // pixel grid
            cv.fillRoundRect(r, rad, RGBA{0.05f, 0.05f, 0.065f, 1});
            const int z = std::max(1, st_->previewZoom);
            const float cell = (float)z * 4.f;
            const float ox = std::round(r.cx()), oy = std::round(r.cy());
            cv.pushClip(r.inset(S(1.f)));
            for (float gx = ox; gx < r.r(); gx += cell) cv.fillRect(Rc{gx, r.y, 1, r.h}, W(0.05f));
            for (float gx = ox - cell; gx > r.x; gx -= cell) cv.fillRect(Rc{gx, r.y, 1, r.h}, W(0.05f));
            for (float gy = oy; gy < r.b(); gy += cell) cv.fillRect(Rc{r.x, gy, r.w, 1}, W(0.05f));
            for (float gy = oy - cell; gy > r.y; gy -= cell) cv.fillRect(Rc{r.x, gy, r.w, 1}, W(0.05f));
            cv.fillRect(Rc{ox, r.y, 1, r.h}, W(0.10f));
            cv.fillRect(Rc{r.x, oy, r.w, 1}, W(0.10f));
            cv.popClip();
            break;
        }
        default: {  // studio: dark stage with a soft accent spotlight
            const RGBA centre{0.085f, 0.082f, 0.10f, 1}, edge{0.018f, 0.018f, 0.024f, 1};
            const RGBA acc = accent_;
            cv.paintRoundRect(r, rad, [&](float x, float y, float* o) {
                const float dx = (x - r.cx()) / (r.w * 0.5f), dy = (y - r.cy()) / (r.h * 0.5f);
                const float d2 = dx * dx + dy * dy;
                RGBA c = mix(centre, edge, smooth(std::min(1.f, d2 * 0.75f)));
                c = mix(c, acc, 0.06f * std::exp(-d2 * 2.5f));
                o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1.f;
            });
            break;
        }
    }
}

void SettingsPanel::drawPreview() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const Rc r = R(636.f, 84.f, 308.f, 292.f);
    previewPx_ = r;
    const float rad = S(18.f);
    if (!cardsBaked_ || baking_) {
        const int c0 = cv.clipX0, c1 = cv.clipY0, c2 = cv.clipX1, c3 = cv.clipY1;
        if (baking_) cv.resetClip();
        cv.shadow(r, rad, S(30.f), Bk(0.50f), S(10.f));
        cv.shadow(r, rad, S(40.f), alpha(accentDeep_, 0.10f), 0.f);
        if (baking_) cv.setClip(c0, c1, c2, c3);
    }
    {
        char k[96];
        std::snprintf(k, sizeof(k), "%d %d %.3f %.3f %.3f %.3f", st.previewBg, st.previewZoom, s_, accent_.r, accent_.g,
                      accent_.b);
        cachedImage(pvBgCache_, "pvbg", r, k, [&](Canvas& c, const Rc& lr) { paintPreviewBackground(c, lr, st.previewBg); });
    }

    // crosshair at true pixel size, magnified by the zoom factor (nearest neighbour)
    const Rc zoomR{r.x + S(12.f), r.b() - S(12.f) - S(30.f), S(112.f), S(30.f)};
    const Rc bgR{r.r() - S(12.f) - S(116.f), r.b() - S(12.f) - S(30.f), S(116.f), S(30.f)};
    bool hovCard = false, heldCard = false;
    if (!hovered(zoomR) && !hovered(bgR)) {
        behave(ID("preview-card"), r, &hovCard, &heldCard);
        if (hovCard) out_->cursor = CURSOR_ARROW;
    }
    const int z = std::max(1, std::min(4, st.previewZoom));
    CrosshairStyle cs = effectiveStyle(st, in_.time);
    auto bit = anim_.find(ID("pv-boost"));
    float boost = bit == anim_.end() ? 0.f : bit->second;
    {
        const float target = (heldCard && st.clickReact != REACT_NONE) ? 1.f : 0.f;
        const float k = 1.f - std::exp(-(target > boost ? 10.f : 4.f) * std::min(in_.dt, 0.1f));
        boost += (target - boost) * k;
        if (std::fabs(target - boost) < 0.002f) boost = target;
        anim_[ID("pv-boost")] = boost;
    }
    const float pulseZoom = st.clickReact == REACT_PULSE ? 1.f + 0.18f * boost : 1.f;
    previewRenderer_.prepare(cs);
    const int bw = (int)std::ceil(r.w / z) + 2, bh = (int)std::ceil(r.h / z) + 2;
    previewBuf_.assign((size_t)bw * bh, 0u);
    float speed = st.spin ? st.spinSpeed : 0.f;
    if (st.clickReact == REACT_SPIN) speed += (speed > 0 ? speed : 180.f) * 2.f * boost;
    previewAngle_ += (st.spinDir == 0 ? 1.f : -1.f) * speed * (kPi / 180.f) * std::min(in_.dt, 0.1f);
    previewAngle_ = std::fmod(previewAngle_, 2.f * kPi);
    previewRenderer_.render(previewBuf_.data(), bw, bh, bw, (float)(bw / 2), (float)(bh / 2), previewAngle_, cs, 0, 0,
                            1 << 30, 1 << 30, pulseZoom);
    cv.pushClip(r.inset(S(2.f)));
    const int ox = (int)std::round(r.cx()) - (bw / 2) * z, oy = (int)std::round(r.cy()) - (bh / 2) * z;
    cv.blit(previewBuf_.data(), bw, bh, bw, ox, oy, z);
    cv.popClip();
    previewAnimating_ = true;  // live label pulse + travelling border light

    // overlay chrome
    const bool light = st.previewBg == 2;
    const RGBA chromeBg = light ? Bk(0.10f) : Bk(0.42f);
    const RGBA chromeLine = light ? Bk(0.10f) : W(0.09f);
    const RGBA chromeTx = light ? Bk(0.72f) : W(0.80f);
    {
        const Rc tag{r.x + S(12.f), r.y + S(12.f), S(104.f), S(26.f)};
        cv.fillRoundRect(tag, S(13.f), chromeBg);
        cv.strokeRoundRect(tag, S(13.f), px1(), chromeLine);
        const float pulse = 0.5f + 0.5f * std::sin((float)in_.time * 4.f);
        cv.fillCircle(tag.x + S(13.f), tag.cy(), S(3.f + 2.f * pulse), RGBA{1.f, 0.3f, 0.36f, 0.22f});
        cv.fillCircle(tag.x + S(13.f), tag.cy(), S(3.f), RGBA{1.f, 0.36f, 0.42f, 1});
        text().drawIn(cv, FONT_BOLD, S(9.5f), Rc{tag.x + S(23.f), tag.y, tag.w, tag.h}, "LIVE PREVIEW", chromeTx, 0,
                      S(1.2f));
    }
    {
        const std::string sp =
            st.spin && st.spinSpeed > 0.f ? fmtInt(st.spinSpeed, "\xC2\xB0/s") : std::string("Static");
        const float tw = text().measure(FONT_SEMIBOLD, S(11.f), sp);
        const Rc chip{r.r() - S(12.f) - tw - S(36.f), r.y + S(12.f), tw + S(36.f), S(26.f)};
        cv.fillRoundRect(chip, S(13.f), chromeBg);
        cv.strokeRoundRect(chip, S(13.f), px1(), chromeLine);
        icon(IC_MOTION, chip.x + S(15.f), chip.cy(), S(12.f), light ? Bk(0.6f) : alpha(accent_, 0.95f));
        text().drawIn(cv, FONT_SEMIBOLD, S(11.f), Rc{chip.x + S(26.f), chip.y, tw, chip.h}, sp, chromeTx, 0);
    }
    {
        const Rc zr = zoomR;
        cv.fillRoundRect(zr, S(10.f), chromeBg);
        cv.strokeRoundRect(zr, S(10.f), px1(), chromeLine);
        const char* zl[3] = {"1\xC3\x97", "2\xC3\x97", "4\xC3\x97"};
        const int zv[3] = {1, 2, 4};
        const float iw = (zr.w - S(6.f)) / 3.f;
        const int cur = z == 1 ? 0 : (z == 2 ? 1 : 2);
        const float sx = spring(ID("zoomsel"), (float)cur, 240.f, 24.f);
        const Rc zp{zr.x + S(3.f) + sx * iw, zr.y + S(3.f), iw, zr.h - S(6.f)};
        cv.fillRoundRectGrad(zp, S(7.f), light ? W(0.95f) : W(0.20f), light ? W(0.85f) : W(0.11f));
        cv.strokeRoundRectGrad(zp, S(7.f), px1(), light ? Bk(0.08f) : W(0.25f), light ? Bk(0.05f) : W(0.04f));
        for (int i = 0; i < 3; ++i) {
            const Rc c{zr.x + S(3.f) + i * iw, zr.y, iw, zr.h};
            if (behave(ID("zoom", i), c) && st.previewZoom != zv[i]) {
                st.previewZoom = zv[i];
                out_->settingsChanged = true;
            }
            text().drawIn(cv, FONT_SEMIBOLD, S(11.5f), c, zl[i],
                          i == cur ? (light ? Bk(0.85f) : W(0.96f)) : alpha(chromeTx, 0.7f), 1);
        }
    }
    {
        const RGBA chipCols[4] = {RGBA{0.06f, 0.06f, 0.08f, 1}, RGBA{0.62f, 0.45f, 0.55f, 1},
                                  RGBA{0.9f, 0.91f, 0.93f, 1}, RGBA{0.2f, 0.2f, 0.24f, 1}};
        const char* names[4] = {"Studio", "Dusk", "Snow", "Grid"};
        const Rc br = bgR;
        cv.fillRoundRect(br, S(10.f), chromeBg);
        cv.strokeRoundRect(br, S(10.f), px1(), chromeLine);
        for (int i = 0; i < 4; ++i) {
            const float cx = br.x + S(17.f) + i * S(27.3f), cyy = br.cy();
            const Rc hit{cx - S(12.f), br.y, S(24.f), br.h};
            bool hv = false;
            if (behave(ID("pvbg", i), hit, &hv) && st.previewBg != i) {
                st.previewBg = i;
                out_->settingsChanged = true;
            }
            tooltip(ID("pvbg", i), hit, names[i]);
            const float sel = anim(ID("pvbgsel", i), st.previewBg == i ? 1.f : 0.f, 16.f);
            if (sel > 0.01f) cv.strokeCircle(cx, cyy, S(9.5f), S(1.6f), alpha(light ? Bk(0.7f) : W(0.92f), sel));
            cv.fillCircle(cx, cyy, S(6.5f + (hv ? 0.7f : 0.f)), chipCols[i]);
            cv.strokeCircle(cx, cyy, S(6.5f), px1(), W(0.28f));
            if (i == 3) {
                cv.pushClip(Rc{cx - S(6.f), cyy - S(6.f), S(12.f), S(12.f)});
                cv.fillRect(Rc{cx - S(0.5f), cyy - S(6.f), S(1.f), S(12.f)}, W(0.5f));
                cv.fillRect(Rc{cx - S(6.f), cyy - S(0.5f), S(12.f), S(1.f)}, W(0.5f));
                cv.popClip();
            }
        }
    }
    // hairline border with a slowly travelling highlight in the accent colour
    const float rot = (float)std::fmod(in_.time * 0.8, 2.0 * kPi);
    const float pcx = r.cx(), pcy = r.cy();
    const RGBA ring = mix(W(1.f), accent_, 0.7f);
    cv.paintRing(r, rad, std::max(1.f, S(1.25f)), [&](float x, float y, float* o) {
        const float ang = std::atan2((y - pcy) / r.h, (x - pcx) / r.w);
        const float d = std::max(0.f, std::cos(ang - rot));
        const float d2 = std::max(0.f, std::cos(ang - rot - kPi));
        const float k = d * d * d * d * d * d;
        const float k2 = std::pow(d2, 8.f) * 0.5f;
        o[0] = ring.r;
        o[1] = ring.g;
        o[2] = ring.b;
        o[3] = 0.10f + 0.75f * k + 0.25f * k2;
    });
}

void SettingsPanel::drawThemes() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const float x0 = 636.f, y0 = 384.f;
    microLabel(x0 + 4.f, y0 + 16.f, "THEMES");
    {
        const std::string cnt = std::to_string(presetCount()) + " presets";
        text().drawIn(cv, FONT_MEDIUM, S(10.5f), R(x0, y0 + 6.f, 304.f, 14.f), cnt, W(0.32f), 2);
    }
    const int cur = matchPreset(st);
    const float cw = (308.f - 3 * 8.f) / 4.f, ch = 68.f;
    CrosshairStyle chipStyle = st.style;
    chipStyle.scale = 0.60f * s_ * std::min(1.4f, std::max(0.6f, st.style.scale));
    chipStyle.shadow = 0.f;
    chipStyle.opacity = 1.f;
    chipRenderer_.prepare(chipStyle);
    for (int i = 0; i < presetCount() && i < 8; ++i) {
        const int col = i % 4, row = i / 4;
        const Rc r = R(x0 + col * (cw + 8.f), y0 + 26.f + row * (ch + 8.f), cw, ch);
        bool hov = false;
        if (behave(ID("theme", i), r, &hov)) {
            applyPreset(st, i);
            st.rainbow = false;
            changed();
        }
        const float hv = anim(ID("themeh", i), hov ? 1.f : 0.f, 16.f);
        const float sel = anim(ID("themes", i), cur == i ? 1.f : 0.f, 14.f);
        const Rc rr = r.offset(0, -S(2.5f) * hv);
        const ColorPreset& p = preset(i);
        cv.shadow(rr, S(13.f), S(18.f), Bk(0.30f + 0.1f * hv), S(4.f + 2.f * hv));
        if (sel > 0.01f) cv.shadow(rr, S(13.f), S(18.f), alpha(p.fill, 0.40f * sel), 0.f);
        cv.fillRoundRectGrad(rr, S(13.f), RGBA{0.12f, 0.12f, 0.15f, 0.92f}, RGBA{0.05f, 0.05f, 0.065f, 0.95f});
        cv.fillRoundRectGrad(rr, S(13.f), alpha(p.glow, 0.05f + 0.08f * hv), alpha(p.glow, 0.0f));
        if (sel > 0.01f)
            cv.strokeRoundRect(rr, S(13.f), S(1.6f), alpha(mix(p.fill, kWhite, 0.2f), 0.95f * sel));
        else
            cv.strokeRoundRectGrad(rr, S(13.f), px1(), W(0.14f + 0.10f * hv), W(0.04f));
        ripple(ID("theme", i), rr, S(13.f), W(0.12f));
        CrosshairStyle cs = chipStyle;
        cs.fill = p.fill;
        cs.line = p.line;
        cs.dotCol = p.dot;
        cs.glowCol = p.glow;
        cs.opacity = cv.globalAlpha;
        if (hov) {
            hoverChipAngle_[i] += in_.dt * 3.2f;
            animating_ = true;
        }
        cv.pushClip(rr.inset(S(1.f)));
        chipRenderer_.render(cv.px, cv.w, cv.h, cv.stride, std::round(rr.cx()), std::round(rr.y + S(28.f)),
                             -0.3175f + hoverChipAngle_[i], cs, cv.clipX0, cv.clipY0, cv.clipX1, cv.clipY1);
        cv.popClip();
        text().drawIn(cv, FONT_SEMIBOLD, S(10.f), Rc{rr.x, rr.b() - S(19.f), rr.w, S(12.f)}, p.name,
                      W(0.52f + 0.4f * std::max(hv, sel)), 1);
        if (sel > 0.05f) {  // check badge
            const float bx = rr.r() - S(11.f), by = rr.y + S(11.f);
            const float br = S(6.5f) * (0.6f + 0.4f * sel);
            cv.fillCircle(bx, by, br + S(1.5f), Bk(0.45f * sel));
            cv.fillCircle(bx, by, br, alpha(mix(p.fill, kWhite, 0.15f), sel));
            icon(IC_CHECK, bx, by, S(8.f), RGBA{0.08f, 0.06f, 0.1f, sel});
        }
    }
    if (button(ID("reset-look"), R(x0, kHeight - 16.f - 42.f, 308.f, 42.f), "Reset to original", 0, IC_RESET)) {
        resetLook(st);
        changed();
        pickLast_ = RGBA{-1, -1, -1, -1};
    }
}

// ============================================================ pages

void SettingsPanel::pageColors(float x, float y, float w) {
    Settings& st = *st_;
    segmented(ID("ctarget"), R(x, y, w, 38.f), {"Blades", "Outline", "Dot", "Glow"}, st.colorTarget, 12.5f);
    RGBA* cols[4] = {&st.style.fill, &st.style.line, &st.style.dotCol, &st.style.glowCol};
    RGBA& c = *cols[std::max(0, std::min(3, st.colorTarget))];
    card(R(x, y + 50.f, w, 322.f), 18.f);
    colorPicker(x + 16.f, y + 66.f, w - 32.f, c);

    const float ry = y + 384.f;
    card(R(x, ry, w, 66.f), 18.f);
    label(x + 16.f, ry + 28.f, "Rainbow cycle", 13.f, FONT_MEDIUM, W(0.90f));
    if (st.rainbow) {
        int sp = st.rainbowSpeed < 0.12f ? 0 : (st.rainbowSpeed < 0.35f ? 1 : 2);
        const int before = sp;
        segmented(ID("rbspeed"), R(x + w - 16.f - 44.f - 14.f - 160.f, ry + 16.f, 160.f, 34.f), {"Slow", "Med", "Fast"},
                  sp, 11.5f);
        if (sp != before) st.rainbowSpeed = sp == 0 ? 0.08f : (sp == 1 ? 0.2f : 0.55f);
        label(x + 16.f, ry + 46.f, "Hue drifts over time", 11.5f, FONT_REGULAR, W(0.46f));
    } else {
        label(x + 16.f, ry + 46.f, "Cycle every color through the spectrum", 11.5f, FONT_REGULAR, W(0.46f));
    }
    toggle(ID("rainbow"), R(x + w - 16.f - 44.f, ry + 21.f, 44.f, 24.f), st.rainbow);
}

void SettingsPanel::colorPicker(float x, float y, float w, RGBA& color) {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const bool external = std::fabs(color.r - pickLast_.r) > 1e-4f || std::fabs(color.g - pickLast_.g) > 1e-4f ||
                          std::fabs(color.b - pickLast_.b) > 1e-4f || pickTarget_ != st.colorTarget;
    if (external) {
        float h, s, v;
        rgbToHsv(color, h, s, v);
        if (s > 1e-4f && v > 1e-4f) pickH_ = h;
        if (v > 1e-4f) pickS_ = s;
        pickV_ = v;
        pickTarget_ = st.colorTarget;
        if (focus_ != ID("hex")) hexEdit_.clear();
    }
    bool modified = false;

    // saturation / value field
    const Rc sv = R(x, y, w, 148.f);
    bool hovSV = false, heldSV = false;
    behave(ID("sv"), sv, &hovSV, &heldSV);
    if (heldSV) {
        pickS_ = clamp01((in_.mx - sv.x) / sv.w);
        pickV_ = 1.f - clamp01((in_.my - sv.y) / sv.h);
        modified = true;
    }
    const float H = pickH_;
    cv.shadow(sv, S(14.f), S(18.f), Bk(0.35f), S(3.f));
    {
        char k[32];
        std::snprintf(k, sizeof(k), "%.4f %.3f", H, s_);
        cachedImage(svCache_, "sv", sv, k, [&](Canvas& c, const Rc& lr) {
            c.paintRoundRect(lr, S(14.f), [&](float px, float py, float* o) {
                const float s = clamp01((px - lr.x) / lr.w), v = 1.f - clamp01((py - lr.y) / lr.h);
                const RGBA col = hsvToRgb(H, s, v);
                o[0] = col.r; o[1] = col.g; o[2] = col.b; o[3] = 1.f;
            });
        });
    }
    cv.strokeRoundRectGrad(sv, S(14.f), px1(), W(0.22f), W(0.08f));
    auto ringThumb = [&](float kx, float ky, float kr, const RGBA& inner) {
        cv.shadow(Rc{kx - kr, ky - kr, kr * 2, kr * 2}, kr, S(8.f), Bk(0.55f), S(2.f));
        cv.fillCircle(kx, ky, kr, W(1.f));
        cv.fillCircle(kx, ky, kr - S(3.f), RGBA{inner.r, inner.g, inner.b, 1.f});
        cv.strokeCircle(kx, ky, kr - S(3.f) + px1() * 0.5f, px1(), Bk(0.15f));
    };
    ringThumb(sv.x + pickS_ * sv.w, sv.y + (1.f - pickV_) * sv.h, S(heldSV ? 11.f : 9.5f),
              hsvToRgb(pickH_, pickS_, pickV_));

    // hue bar
    const Rc hue = R(x, y + 162.f, w, 16.f);
    bool heldH = false;
    behave(ID("hue"), hue.inset(0, -S(5.f)), nullptr, &heldH);
    if (heldH) {
        pickH_ = clamp01((in_.mx - hue.x) / hue.w) * 0.9999f;
        modified = true;
    }
    cachedImage(hueCache_, "hue", hue, std::to_string(s_), [&](Canvas& c, const Rc& lr) {
        c.paintRoundRect(lr, lr.h * 0.5f, [&](float px, float, float* o) {
            const RGBA col = hsvToRgb(clamp01((px - lr.x) / lr.w) * 0.9999f, 1.f, 1.f);
            o[0] = col.r; o[1] = col.g; o[2] = col.b; o[3] = 1.f;
        });
    });
    cv.strokeRoundRect(hue, hue.h * 0.5f, px1(), Bk(0.18f));
    ringThumb(hue.x + pickH_ * hue.w, hue.cy(), S(heldH ? 11.f : 10.f), hsvToRgb(pickH_, 1.f, 1.f));

    // alpha bar
    const Rc al = R(x, y + 188.f, w, 16.f);
    bool heldA = false;
    behave(ID("alpha"), al.inset(0, -S(5.f)), nullptr, &heldA);
    if (heldA) {
        color.a = std::round(clamp01((in_.mx - al.x) / al.w) * 100.f) / 100.f;
        changed();
    }
    const RGBA base = hsvToRgb(pickH_, pickS_, pickV_);
    const float cell = S(5.f);
    {
        char k[64];
        std::snprintf(k, sizeof(k), "%.4f %.4f %.4f %.3f", base.r, base.g, base.b, s_);
        cachedImage(alphaCache_, "alpha", al, k, [&](Canvas& c, const Rc& lr) {
            c.paintRoundRect(lr, lr.h * 0.5f, [&](float px, float py, float* o) {
                const int cx = (int)std::floor((px - lr.x) / cell), cy = (int)std::floor((py - lr.y) / cell);
                const float chk = ((cx + cy) & 1) ? 0.42f : 0.26f;
                const float t = clamp01((px - lr.x) / lr.w);
                o[0] = chk + (base.r - chk) * t;
                o[1] = chk + (base.g - chk) * t;
                o[2] = chk + (base.b - chk) * t;
                o[3] = 1.f;
            });
        });
    }
    cv.strokeRoundRect(al, al.h * 0.5f, px1(), Bk(0.18f));
    ringThumb(al.x + color.a * al.w, al.cy(), S(heldA ? 11.f : 10.f), base);

    if (modified) {
        const float a = color.a;
        color = hsvToRgb(pickH_, pickS_, pickV_, a);
        changed();
    }

    // value row: swatch, hex field, alpha readout, copy
    const float ry = y + 216.f;
    const Rc sw = R(x, ry, 38.f, 38.f);
    cv.shadow(sw, S(11.f), S(10.f), alpha(RGBA{color.r, color.g, color.b, 1}, 0.35f), 0.f);
    cv.fillRoundRect(sw, S(11.f), W(0.16f));
    cv.fillRoundRect(sw.inset(S(3.f)), S(8.f), RGBA{color.r, color.g, color.b, 1.f});
    cv.strokeRoundRectGrad(sw, S(11.f), px1(), W(0.30f), W(0.08f));
    hexField(ID("hex"), R(x + 48.f, ry, 122.f, 38.f), color);
    {
        const Rc ar = R(x + 180.f, ry, 62.f, 38.f);
        cv.fillRoundRect(ar, S(11.f), Bk(0.28f));
        cv.strokeRoundRectGrad(ar, S(11.f), px1(), Bk(0.25f), W(0.07f));
        text().drawIn(cv, FONT_SEMIBOLD, S(12.5f), ar, fmtInt(color.a * 100.f, "%"), W(0.88f), 1);
    }
    if (button(ID("copyhex"), R(x + 252.f, ry, w - 252.f, 38.f), "Copy", 0, IC_COPY))
        out_->copyText = toHex(color, color.a < 0.999f);

    // swatches
    const float sy = y + 268.f;
    const int n = 12;
    const float d = 22.f;
    const float gap = (w - n * d) / (n - 1);
    for (int i = 0; i < n; ++i) {
        const Rc r = R(x + i * (d + gap), sy, d, d);
        bool hov = false;
        if (behave(ID("swatch", i), r.inset(-S(3.f)), &hov)) {
            const float a = color.a;
            color = hexc(kSwatches[i], a);
            changed();
        }
        const RGBA c = hexc(kSwatches[i]);
        const bool same = std::fabs(c.r - color.r) < 0.004f && std::fabs(c.g - color.g) < 0.004f &&
                          std::fabs(c.b - color.b) < 0.004f;
        const float hv = spring(ID("swh", i), hov ? 1.f : 0.f, 300.f, 18.f);
        const float rr = S(d * 0.5f) + S(2.f) * hv;
        if (same) cv.strokeCircle(r.cx(), r.cy(), rr + S(3.5f), S(1.8f), W(0.92f));
        if (hv > 0.01f)
            cv.shadow(Rc{r.cx() - rr, r.cy() - rr, rr * 2, rr * 2}, rr, S(8.f), alpha(c, 0.5f * clamp01(hv)), 0.f);
        cv.fillCircle(r.cx(), r.cy(), rr, c);
        cv.strokeCircle(r.cx(), r.cy(), rr - S(0.5f), px1(), Bk(0.20f));
        cv.fillCircle(r.cx() - rr * 0.28f, r.cy() - rr * 0.32f, rr * 0.30f, W(0.22f));  // gloss
    }
}

void SettingsPanel::hexField(uint32_t id, const Rc& r, RGBA& color) {
    Canvas& cv = *cv_;
    bool hov = false;
    if (behave(id, r, &hov)) {
        if (focus_ != id) {
            focus_ = id;
            hexEdit_ = toHex(color, color.a < 0.999f).substr(1);
            caret_ = hexEdit_.size();
            hexSelectAll_ = true;
            caretTime_ = in_.time;
        }
    }
    if (hov) out_->cursor = CURSOR_IBEAM;
    const bool focused = focus_ == id;
    if (focused) {
        bool edited = false;
        if (in_.kPaste && !in_.clipboard.empty()) {
            std::string p;
            for (char ch : in_.clipboard)
                if (std::isxdigit((unsigned char)ch)) p += (char)std::toupper((unsigned char)ch);
            if (hexSelectAll_) {
                hexEdit_.clear();
                caret_ = 0;
                hexSelectAll_ = false;
            }
            hexEdit_.insert(caret_, p.substr(0, 8 - std::min<size_t>(8, hexEdit_.size())));
            caret_ = std::min(hexEdit_.size(), caret_ + p.size());
            edited = true;
        }
        for (char ch : in_.typed) {
            if (!std::isxdigit((unsigned char)ch)) continue;
            if (hexSelectAll_) {
                hexEdit_.clear();
                caret_ = 0;
                hexSelectAll_ = false;
            }
            if (hexEdit_.size() >= 8) continue;
            hexEdit_.insert(hexEdit_.begin() + (long)caret_, (char)std::toupper((unsigned char)ch));
            ++caret_;
            edited = true;
        }
        if (in_.kSelectAll) hexSelectAll_ = true;
        if (in_.kBack) {
            if (hexSelectAll_) {
                hexEdit_.clear();
                caret_ = 0;
                hexSelectAll_ = false;
            } else if (caret_ > 0) {
                hexEdit_.erase(caret_ - 1, 1);
                --caret_;
            }
            edited = true;
        }
        if (in_.kDelete) {
            if (hexSelectAll_) {
                hexEdit_.clear();
                caret_ = 0;
                hexSelectAll_ = false;
            } else if (caret_ < hexEdit_.size()) {
                hexEdit_.erase(caret_, 1);
            }
            edited = true;
        }
        if (in_.kLeft && caret_ > 0) {
            --caret_;
            hexSelectAll_ = false;
        }
        if (in_.kRight && caret_ < hexEdit_.size()) {
            ++caret_;
            hexSelectAll_ = false;
        }
        if (in_.kHome) {
            caret_ = 0;
            hexSelectAll_ = false;
        }
        if (in_.kEnd) {
            caret_ = hexEdit_.size();
            hexSelectAll_ = false;
        }
        if (in_.kCopy) out_->copyText = "#" + hexEdit_;
        if (edited) caretTime_ = in_.time;
        RGBA parsed;
        if (edited && (hexEdit_.size() == 6 || hexEdit_.size() == 8) && parseHex(hexEdit_, parsed)) {
            if (hexEdit_.size() == 6) parsed.a = color.a;
            color = parsed;
            changed();
        }
        if (in_.kEnter || in_.kEscape) {
            focus_ = 0;
            hexEdit_.clear();
        }
    }
    const float fa = anim(id ^ 0x3u, focused ? 1.f : 0.f, 18.f);
    const float rad = S(11.f);
    if (fa > 0.01f) cv.shadow(r, rad, S(12.f), alpha(accent_, 0.50f * fa), 0.f, S(1.f));
    cv.fillRoundRect(r, rad, Bk(0.28f + 0.1f * fa));
    cv.strokeRoundRectGrad(r, rad, px1(), mix(Bk(0.25f), accent_, fa),
                           mix(W(0.07f + 0.06f * (hov ? 1.f : 0.f)), accent_, fa));
    const std::string shown = focused ? hexEdit_ : toHex(color, false).substr(1);
    const float tx = r.x + S(14.f);
    const float hashW = text().draw(cv, FONT_MEDIUM, S(13.f), tx,
                                    r.cy() + text().capHeight(FONT_MEDIUM, S(13.f)) * 0.5f, "#", W(0.38f));
    const float vx0 = tx + hashW + S(2.f);
    const float baseline = r.cy() + text().capHeight(FONT_SEMIBOLD, S(13.f)) * 0.5f;
    if (focused && hexSelectAll_ && !hexEdit_.empty()) {
        const float swd = text().measure(FONT_SEMIBOLD, S(13.f), hexEdit_, S(0.6f));
        cv.fillRoundRect(Rc{vx0 - S(2.f), r.cy() - S(10.f), swd + S(4.f), S(20.f)}, S(4.f), alpha(accent_, 0.35f));
    }
    text().draw(cv, FONT_SEMIBOLD, S(13.f), vx0, baseline, shown, W(0.94f), S(0.6f));
    if (focused) {
        const float blink = std::fmod((float)(in_.time - caretTime_), 1.06f) < 0.53f ? 1.f : 0.f;
        if (blink > 0.f) {
            const float cx = vx0 + text().measure(FONT_SEMIBOLD, S(13.f), hexEdit_.substr(0, caret_), S(0.6f)) +
                             (caret_ > 0 ? S(0.6f) : 0.f);
            cv.fillRect(Rc{std::round(cx), r.cy() - S(8.f), std::max(1.f, S(1.5f)), S(16.f)}, accent_);
        }
    }
}

void SettingsPanel::pageShape(float x, float y, float w) {
    Settings& st = *st_;
    CrosshairStyle& c = st.style;
    card(R(x, y, w, 342.f), 18.f);
    const float ix = x + 16.f, iw = w - 32.f;
    float yy = y + 14.f;
    sliderRow(ID("scale"), ix, yy, iw, "Size", fmtInt(c.scale * 100.f, "%"), c.scale, 0.5f, 4.f, 0.05f);
    yy += 54.f;
    sliderRow(ID("length"), ix, yy, iw, "Blade length", fmt1(c.length, " px"), c.length, 6.f, 60.f, 0.1f);
    yy += 54.f;
    sliderRow(ID("width"), ix, yy, iw, "Blade width", fmt1(c.width, " px"), c.width, 2.f, 24.f, 0.1f);
    yy += 54.f;
    sliderRow(ID("gap"), ix, yy, iw, "Center gap", fmt1(c.gap, " px"), c.gap, 0.f, 30.f, 0.1f);
    yy += 54.f;
    {
        label(ix, yy + 15.f, "Outline", 13.f, FONT_MEDIUM, W(0.88f));
        toggle(ID("outline-on"), R(ix + 62.f, yy + 3.f, 34.f, 19.f), c.showOutline);
        valuePill(ix + iw, yy + 1.f, c.showOutline ? fmt1(c.outline, " px") : std::string("Off"));
        const float ga = cv_->globalAlpha;
        if (!c.showOutline) cv_->globalAlpha = ga * 0.4f;
        slider(ID("outline"), R(ix, yy + 27.f, iw, 22.f), c.outline, 0.f, 4.f, 0.05f);
        cv_->globalAlpha = ga;
    }
    yy += 54.f;
    sliderRow(ID("dot"), ix, yy, iw, "Center dot", c.dot > 0.01f ? fmt1(c.dot, " px") : std::string("Off"), c.dot, 0.f,
              6.f, 0.05f);

    const float by = y + 354.f;
    card(R(x, by, w, 68.f), 18.f);
    label(ix, by + 39.f, "Blades", 13.f, FONT_MEDIUM, W(0.88f));
    static const int counts[6] = {2, 3, 4, 5, 6, 8};
    int sel = 2;
    for (int i = 0; i < 6; ++i)
        if (counts[i] == c.blades) sel = i;
    if (segmented(ID("blades"), R(ix + 76.f, by + 15.f, iw - 76.f, 38.f), {"2", "3", "4", "5", "6", "8"}, sel, 12.5f))
        c.blades = counts[sel];
}

void SettingsPanel::pageMotion(float x, float y, float w) {
    Settings& st = *st_;
    const float ix = x + 16.f, iw = w - 32.f;
    card(R(x, y, w, 232.f), 18.f);
    float yy = y + 10.f;
    toggleRow(ID("spin"), ix, yy, iw, "Spin", "Rotate the crosshair continuously", st.spin);
    cv_->fillRect(R(ix, yy + 54.f, iw, 1.f), W(0.06f));
    yy += 62.f;
    char v[48];
    std::snprintf(v, sizeof(v), "%d\xC2\xB0/s  \xC2\xB7  %.2f rps", (int)std::lround(st.spinSpeed), st.spinSpeed / 360.f);
    const float ga = cv_->globalAlpha;
    if (!st.spin) cv_->globalAlpha = ga * 0.45f;
    sliderRow(ID("speed"), ix, yy, iw, "Speed", v, st.spinSpeed, 0.f, 1080.f, 5.f);
    yy += 58.f;
    {
        static const float speeds[4] = {60.f, 150.f, 360.f, 720.f};
        static const char* names[4] = {"Chill", "Smooth", "Fast", "Turbo"};
        const float cw = (iw - 3 * 8.f) / 4.f;
        for (int i = 0; i < 4; ++i) {
            const Rc r = R(ix + i * (cw + 8.f), yy, cw, 32.f);
            bool hov = false;
            if (behave(ID("spdchip", i), r, &hov)) {
                st.spinSpeed = speeds[i];
                st.spin = true;
                changed();
            }
            const bool on = std::fabs(st.spinSpeed - speeds[i]) < 0.5f;
            const float hv = anim(ID("spdchiph", i), hov ? 1.f : 0.f, 18.f);
            if (on) cv_->shadow(r, S(10.f), S(12.f), alpha(accentDeep_, 0.35f), 0.f);
            cv_->fillRoundRectGrad(r, S(10.f), on ? alpha(accent_, 0.24f) : W(0.07f + 0.04f * hv),
                                   on ? alpha(accentDeep_, 0.16f) : W(0.03f + 0.03f * hv));
            cv_->strokeRoundRectGrad(r, S(10.f), px1(), on ? alpha(accent_, 0.75f) : W(0.16f + 0.06f * hv),
                                     on ? alpha(accent_, 0.35f) : W(0.04f));
            ripple(ID("spdchip", i), r, S(10.f), W(0.12f));
            text().drawIn(*cv_, FONT_SEMIBOLD, S(12.f), r, names[i], on ? accentText_ : W(0.72f + 0.2f * hv), 1);
        }
    }
    yy += 46.f;
    label(ix, yy + 24.f, "Direction", 13.f, FONT_MEDIUM, W(0.88f));
    segmented(ID("dir"), R(ix + 96.f, yy + 4.f, iw - 96.f, 36.f), {"Clockwise", "Counter"}, st.spinDir, 12.5f);
    cv_->globalAlpha = ga;

    const float cy = y + 244.f;
    card(R(x, cy, w, 124.f), 18.f);
    label(ix, cy + 28.f, "Click reaction", 13.f, FONT_MEDIUM, W(0.90f));
    label(ix, cy + 46.f, "React while a mouse button is held. Try it on the preview.", 11.5f, FONT_REGULAR, W(0.46f));
    segmented(ID("react"), R(ix, cy + 66.f, iw, 38.f), {"None", "Spin boost", "Pulse"}, st.clickReact, 12.5f);
}

void SettingsPanel::pageEffects(float x, float y, float w) {
    Settings& st = *st_;
    CrosshairStyle& c = st.style;
    const float ix = x + 16.f, iw = w - 32.f;
    card(R(x, y, w, 288.f), 18.f);
    float yy = y + 14.f;
    float g = c.glow * 100.f, gs = c.glowSize * 100.f, h = c.halo * 100.f, sh = c.shadow * 100.f,
          op = c.opacity * 100.f;
    sliderRow(ID("glow"), ix, yy, iw, "Glow strength", fmtInt(g, "%"), g, 0.f, 250.f, 1.f);
    yy += 54.f;
    sliderRow(ID("glowsize"), ix, yy, iw, "Glow spread", fmtInt(gs, "%"), gs, 50.f, 300.f, 1.f);
    yy += 54.f;
    sliderRow(ID("halo"), ix, yy, iw, "Dot halo", fmtInt(h, "%"), h, 0.f, 300.f, 1.f);
    yy += 54.f;
    sliderRow(ID("shadow"), ix, yy, iw, "Contrast shadow", sh < 0.5f ? std::string("Off") : fmtInt(sh, "%"), sh, 0.f,
              100.f, 1.f);
    yy += 54.f;
    sliderRow(ID("opacity"), ix, yy, iw, "Opacity", fmtInt(op, "%"), op, 10.f, 100.f, 1.f);
    c.glow = g / 100.f;
    c.glowSize = gs / 100.f;
    c.halo = h / 100.f;
    c.shadow = sh / 100.f;
    c.opacity = op / 100.f;

    const float ty = y + 300.f;
    card(R(x, ty, w, 86.f), 18.f);
    iconTile(IC_TARGET, R(ix, ty + 18.f, 30.f, 30.f), 3, 0.6f);
    label(ix + 44.f, ty + 30.f, "Pro tip", 12.5f, FONT_SEMIBOLD, accentText_);
    label(ix + 44.f, ty + 50.f, "Bright map? Add a little contrast shadow so the", 11.5f, FONT_REGULAR, W(0.56f));
    label(ix + 44.f, ty + 66.f, "white outline stays readable on snow and sky.", 11.5f, FONT_REGULAR, W(0.56f));
}

void SettingsPanel::pageSettings(float x, float y, float w) {
    Settings& st = *st_;
    const float ix = x + 16.f, iw = w - 32.f;
    card(R(x, y, w, 138.f), 18.f);
    label(ix, y + 30.f, "Position", 13.f, FONT_MEDIUM, W(0.90f));
    segmented(ID("pos"), R(ix + 90.f, y + 12.f, iw - 90.f, 36.f), {"Follow cursor", "Screen center"}, st.position,
              12.5f);
    {
        float ox = (float)st.offsetX, oy = (float)st.offsetY;
        const float hw = (iw - 16.f) / 2.f;
        sliderRow(ID("offx"), ix, y + 64.f, hw, "Nudge X", fmtInt(ox, " px"), ox, -50.f, 50.f, 1.f);
        sliderRow(ID("offy"), ix + hw + 16.f, y + 64.f, hw, "Nudge Y", fmtInt(oy, " px"), oy, -50.f, 50.f, 1.f);
        st.offsetX = (int)std::lround(ox);
        st.offsetY = (int)std::lround(oy);
    }
    const float ty = y + 150.f;
    card(R(x, ty, w, 168.f), 18.f);
    toggleRow(ID("hidecur"), ix, ty + 6.f, iw, "Hide Windows cursor", "The crosshair becomes your pointer", st.hideCursor);
    cv_->fillRect(R(ix, ty + 57.f, iw, 1.f), W(0.06f));
    toggleRow(ID("hidecap"), ix, ty + 59.f, iw, "Hide from screen capture", "Invisible to OBS, Discord and screenshots",
              st.hideFromCapture);
    cv_->fillRect(R(ix, ty + 110.f, iw, 1.f), W(0.06f));
    toggleRow(ID("autostart"), ix, ty + 112.f, iw, "Start with Windows", "Launch quietly in the tray",
              st.startWithWindows);
    const float ky = y + 330.f;
    card(R(x, ky, w, 108.f), 18.f);
    auto bindRow = [&](int which, float yy, const char* name, int vk) {
        label(ix, yy + 23.f, name, 13.f, FONT_MEDIUM, W(0.90f));
        const bool cap = status_->capturing == which;
        const std::string kn = cap ? std::string("Press a key\xE2\x80\xA6") : keyName(vk);
        const float kw = std::max(S(100.f), text().measure(FONT_SEMIBOLD, S(12.5f), kn) + S(30.f));
        const Rc kr = R(ix + iw, yy + 4.f, 0.f, 32.f);
        const Rc key{kr.x - kw, kr.y, kw, kr.h};
        bool hov = false;
        if (behave(ID("bind", which), key, &hov)) {
            if (cap)
                out_->cancelBind = true;
            else
                out_->bindKey = which;
        }
        if (hov) bindHovered_ = true;
        if (cap) animating_ = true;
        keycap(key.offset(0, hov ? -S(1.f) : 0.f), kn, cap);
        if (which == 2 && vk != 0 && !cap) {
            const Rc clr{key.x - S(38.f), key.y, S(32.f), S(32.f)};
            if (iconButton(ID("bindclr"), clr, IC_CLOSE, "Clear key")) out_->clearToggleKey = true;
        }
    };
    bindRow(1, ky + 12.f, "Menu key", st.menuKey);
    cv_->fillRect(R(ix, ky + 54.f, iw, 1.f), W(0.06f));
    bindRow(2, ky + 60.f, "Show / hide crosshair", st.toggleKey);
}

}  // namespace vx
