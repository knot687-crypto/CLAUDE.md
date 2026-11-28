// Vortex Crosshair - glass settings panel (immediate mode, software rendered)
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
inline float lerp(float a, float b, float t) { return a + (b - a) * t; }
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

bool SettingsPanel::hovered(const Rc& r) const { return r.contains(in_.mx, in_.my); }

bool SettingsPanel::behave(uint32_t id, const Rc& r, bool* hover, bool* held) {
    const bool over = hovered(r) && (active_ == 0 || active_ == id);
    if (over) hot_ = id;
    bool clicked = false;
    if (over && in_.mousePressed) {
        active_ = id;
        if (focus_ != id) focus_ = 0;
    }
    if (active_ == id && in_.mouseReleased) {
        if (hovered(r)) clicked = true;
    }
    if (hover) *hover = over;
    if (held) *held = active_ == id && in_.mouseDown;
    if (over) out_->cursor = CURSOR_HAND;
    return clicked;
}

void SettingsPanel::label(float x, float y, const std::string& t, float size, int face, const RGBA& c,
                          float tracking) {
    text().draw(*cv_, face, S(size), S(x), S(y), t, c, S(tracking));
}

void SettingsPanel::resetInteraction() {
    active_ = 0;
    hot_ = 0;
    focus_ = 0;
}

bool SettingsPanel::dragArea(float x, float y) const {
    if (y < 0 || y > S(64.f)) return false;
    for (const Rc& r : headerHits_)
        if (r.contains(x, y)) return false;
    return true;
}

void SettingsPanel::computeAccent() {
    float h, s, v;
    const RGBA f = st_->style.fill;
    rgbToHsv(f, h, s, v);
    if (s < 0.08f || v < 0.15f) {
        // neutral colours -> elegant silver accent
        accent_ = RGBA{0.93f, 0.93f, 0.97f, 1};
        accentDeep_ = RGBA{0.70f, 0.71f, 0.78f, 1};
        accentText_ = RGBA{0.92f, 0.92f, 0.96f, 1};
        return;
    }
    accent_ = hsvToRgb(h, std::min(0.62f, std::max(0.38f, s * 1.9f)), 1.0f);
    accentDeep_ = hsvToRgb(h, std::min(0.85f, std::max(0.62f, s * 3.0f)), 0.93f);
    accentText_ = hsvToRgb(h, std::min(0.45f, std::max(0.28f, s * 1.4f)), 1.0f);
}

// ============================================================ widgets

void SettingsPanel::card(const Rc& r, float radius) {
    cv_->fillRoundRectGrad(r, S(radius), W(0.055f), W(0.028f));
    cv_->strokeRoundRectGrad(r, S(radius), std::max(1.f, S(1.f)), W(0.11f), W(0.045f));
}

bool SettingsPanel::toggle(uint32_t id, const Rc& r, bool& v) {
    bool hov = false;
    const bool clicked = behave(id, r.inset(-S(4)), &hov);
    if (clicked) {
        v = !v;
        changed();
    }
    const float t = anim(id, v ? 1.f : 0.f, 16.f);
    const float h = r.h;
    const float hv = anim(id ^ 0x55u, hov ? 1.f : 0.f, 18.f);
    // track
    const RGBA off = W(0.13f + 0.05f * hv);
    cv_->fillRoundRect(r, h * 0.5f, off);
    if (t > 0.001f) {
        RGBA a0 = accentDeep_, a1 = accent_;
        a0.a *= t;
        a1.a *= t;
        cv_->fillRoundRectGrad(r, h * 0.5f, a0, a1, false);
    }
    cv_->strokeRoundRect(r, h * 0.5f, std::max(1.f, S(1.f)), W(0.10f * (1 - t) + 0.12f * t));
    // knob
    const float kr = h * 0.5f - S(3.f);
    const float kx = r.x + h * 0.5f + t * (r.w - h);
    const float ky = r.cy();
    cv_->shadow(Rc{kx - kr, ky - kr, kr * 2, kr * 2}, kr, S(4.f), Bk(0.35f), S(1.f));
    cv_->fillCircle(kx, ky, kr, RGBA{1, 1, 1, 0.97f});
    return clicked;
}

bool SettingsPanel::slider(uint32_t id, const Rc& r, float& v, float lo, float hi, float step) {
    bool hov = false, held = false;
    behave(id, r.inset(0, -S(4)), &hov, &held);
    bool ch = false;
    if (held) {
        float t = clamp01((in_.mx - r.x) / r.w);
        float nv = lo + t * (hi - lo);
        if (step > 0) nv = std::round(nv / step) * step;
        nv = std::max(lo, std::min(hi, nv));
        if (nv != v) {
            v = nv;
            ch = true;
        }
    } else if (hov && in_.wheel != 0.f) {
        const float st = step > 0 ? step : (hi - lo) / 100.f;
        float nv = std::max(lo, std::min(hi, v + st * (in_.wheel > 0 ? 1.f : -1.f)));
        if (nv != v) {
            v = nv;
            ch = true;
        }
    }
    if (ch) changed();
    const float t = clamp01((v - lo) / (hi - lo));
    const float cy = r.cy();
    const float th = S(4.f);
    const Rc track{r.x, cy - th * 0.5f, r.w, th};
    cv_->fillRoundRect(track, th * 0.5f, W(0.11f));
    const float tw = std::max(th, r.w * t);
    cv_->fillRoundRectGrad(Rc{r.x, track.y, tw, th}, th * 0.5f, accentDeep_, accent_, false);
    const float hv = anim(id ^ 0x77u, (hov || held) ? 1.f : 0.f, 18.f);
    const float dr = anim(id ^ 0x99u, held ? 1.f : 0.f, 20.f);
    const float kx = r.x + r.w * t;
    const float kr = S(7.f) + S(1.5f) * hv;
    if (dr > 0.01f) cv_->fillCircle(kx, cy, kr + S(6.f) * dr, alpha(accent_, 0.18f * dr));
    cv_->shadow(Rc{kx - kr, cy - kr, kr * 2, kr * 2}, kr, S(5.f), Bk(0.45f), S(1.f));
    cv_->fillCircle(kx, cy, kr, RGBA{1, 1, 1, 1});
    cv_->fillCircle(kx, cy, kr * 0.42f, alpha(accentDeep_, 0.9f * (0.35f + 0.65f * hv)));
    return ch;
}

bool SettingsPanel::segmented(uint32_t id, const Rc& r, const std::vector<std::string>& items, int& sel,
                              float fontSize) {
    const int n = (int)items.size();
    if (n == 0) return false;
    cv_->fillRoundRect(r, S(10.f), Bk(0.22f));
    cv_->strokeRoundRect(r, S(10.f), std::max(1.f, S(1.f)), W(0.07f));
    const float iw = (r.w - S(6.f)) / n;
    const float sx = anim(id, (float)sel, 18.f);
    const Rc pill{r.x + S(3.f) + sx * iw, r.y + S(3.f), iw, r.h - S(6.f)};
    cv_->shadow(pill, S(8.f), S(6.f), Bk(0.35f), S(1.f));
    cv_->fillRoundRectGrad(pill, S(8.f), W(0.17f), W(0.11f));
    cv_->strokeRoundRectGrad(pill, S(8.f), std::max(1.f, S(1.f)), W(0.16f), W(0.06f));
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
        const RGBA col = W(0.55f + 0.17f * hv + 0.33f * isSel);
        text().drawIn(*cv_, isSel > 0.5f ? FONT_SEMIBOLD : FONT_MEDIUM, S(fontSize), cell, items[i], col, 1);
    }
    return changedSel;
}

bool SettingsPanel::button(uint32_t id, const Rc& r, const std::string& t, int style, int ic) {
    bool hov = false, held = false;
    const bool clicked = behave(id, r, &hov, &held);
    const float hv = anim(id, hov ? 1.f : 0.f, 18.f);
    const float pr = anim(id ^ 0x5u, held ? 1.f : 0.f, 25.f);
    const float rad = S(11.f);
    RGBA txt = W(0.9f);
    if (style == 1) {  // primary
        cv_->shadow(r, rad, S(14.f), alpha(accentDeep_, 0.35f + 0.2f * hv), S(3.f));
        cv_->fillRoundRectGrad(r, rad, mix(accent_, kWhite, 0.15f * hv), mix(accentDeep_, kWhite, 0.1f * hv));
        cv_->strokeRoundRectGrad(r, rad, std::max(1.f, S(1.f)), W(0.45f), W(0.08f));
        txt = RGBA{0.06f, 0.05f, 0.08f, 0.92f};
    } else if (style == 2) {  // danger
        const RGBA red{1.f, 0.33f, 0.36f, 1};
        cv_->fillRoundRect(r, rad, alpha(red, 0.12f + 0.12f * hv + 0.1f * pr));
        cv_->strokeRoundRect(r, rad, std::max(1.f, S(1.f)), alpha(red, 0.35f + 0.25f * hv));
        txt = RGBA{1.f, 0.72f, 0.74f, 1};
    } else {  // secondary glass
        cv_->fillRoundRectGrad(r, rad, W(0.08f + 0.05f * hv - 0.03f * pr), W(0.045f + 0.04f * hv));
        cv_->strokeRoundRectGrad(r, rad, std::max(1.f, S(1.f)), W(0.14f + 0.06f * hv), W(0.05f));
    }
    const float tw = text().measure(FONT_SEMIBOLD, S(13.f), t);
    float x = r.cx() - tw * 0.5f;
    if (ic >= 0) {
        const float isz = S(14.f);
        x += (isz + S(8.f)) * 0.5f;
        icon(ic, x - S(8.f) - isz * 0.5f, r.cy(), isz, txt);
    }
    text().draw(*cv_, FONT_SEMIBOLD, S(13.f), x, r.cy() + text().capHeight(FONT_SEMIBOLD, S(13.f)) * 0.5f, t, txt);
    return clicked;
}

bool SettingsPanel::iconButton(uint32_t id, const Rc& r, int ic) {
    bool hov = false, held = false;
    const bool clicked = behave(id, r, &hov, &held);
    const float hv = anim(id, hov ? 1.f : 0.f, 18.f);
    if (hv > 0.01f) {
        const RGBA bg = ic == IC_POWER ? RGBA{1.f, 0.35f, 0.38f, 0.22f * hv} : W(0.09f * hv + (held ? 0.04f : 0.f));
        cv_->fillRoundRect(r, S(10.f), bg);
    }
    icon(ic, r.cx(), r.cy(), S(15.f), W(0.62f + 0.33f * hv));
    return clicked;
}

void SettingsPanel::keycap(const Rc& r, const std::string& t, bool glowing) {
    const float rad = S(8.f);
    if (glowing) cv_->shadow(r, rad, S(16.f), alpha(accent_, 0.55f), 0.f, S(1.f));
    cv_->fillRoundRect(r.offset(0, S(2.f)), rad, Bk(0.45f));
    cv_->fillRoundRectGrad(r, rad, W(0.20f), W(0.10f));
    cv_->strokeRoundRectGrad(r, rad, std::max(1.f, S(1.f)), W(0.30f), W(0.08f));
    text().drawIn(*cv_, FONT_SEMIBOLD, S(12.5f), r, t, glowing ? accentText_ : W(0.92f), 1);
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
            // a single blade: translucent rhombus with a crisp outline
            const float a = 7.2f * u, b = 3.6f * u;
            const float pts[8] = {cx, cy - a, cx + b, cy, cx, cy + a, cx - b, cy};
            cv.fillPoly(pts, 4, alpha(c, 0.28f));
            for (int i = 0; i < 4; ++i) {
                const int j = (i + 1) % 4;
                cv.line(pts[2 * i], pts[2 * i + 1], pts[2 * j], pts[2 * j + 1], lw, c);
            }
            break;
        }
        case IC_MOTION: {
            cv.arc(cx, cy, 5.6f * u, -kPi * 0.95f, kPi * 0.55f, lw, c);
            // arrow head at the end (angle 0.55pi)
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
                // concave star: draw as 4 triangles from centre
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
    label(x, y + 14.f, name, 13.f, FONT_MEDIUM, W(0.86f));
    const float vw = text().measure(FONT_SEMIBOLD, S(12.f), value);
    // value pill
    const Rc pill{S(x + w) - vw - S(16.f), S(y + 1.f), vw + S(16.f), S(20.f)};
    cv_->fillRoundRect(pill, S(6.f), W(0.06f));
    text().drawIn(*cv_, FONT_SEMIBOLD, S(12.f), pill, value, accentText_, 1);
    slider(id, R(x, y + 26.f, w, 20.f), v, lo, hi, step);
}

void SettingsPanel::toggleRow(uint32_t id, float x, float y, float w, const std::string& name,
                              const std::string& desc, bool& v) {
    label(x, y + 16.f, name, 13.f, FONT_MEDIUM, W(0.88f));
    if (!desc.empty()) label(x, y + 34.f, desc, 11.5f, FONT_REGULAR, W(0.46f));
    toggle(id, R(x + w - 42.f, y + 9.f, 42.f, 24.f), v);
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
    computeAccent();

    // Decide between a full redraw and a cheap preview-only redraw. Anything that
    // could change pixels outside the preview card forces a full frame.
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

    cv.globalAlpha = 1.f;
    const Rc pv = R(616.f, 82.f, 288.f, 288.f);
    if (full) {
        cv.resetClip();
        cv.clear(0);
        dirty_ = Rc{0, 0, (float)cv.w, (float)cv.h};
    } else {
        cv.setClip(pv);
        cv.clearRect(cv.clipX0, cv.clipY0, cv.clipX1, cv.clipY1, 0);
        dirty_ = Rc{(float)cv.clipX0, (float)cv.clipY0, (float)(cv.clipX1 - cv.clipX0), (float)(cv.clipY1 - cv.clipY0)};
    }
    const int fx0 = cv.clipX0, fy0 = cv.clipY0, fx1 = cv.clipX1, fy1 = cv.clipY1;
    auto restoreClip = [&]() { cv.setClip(fx0, fy0, fx1, fy1); };

    drawBackground();
    restoreClip();
    drawHeader();
    restoreClip();
    drawSidebar();
    restoreClip();

    // ---- page content with a soft fade/slide transition
    if (st.page != prevPage_) {
        pageSwitchTime_ = in.time;
        prevPage_ = st.page;
        focus_ = 0;
    }
    const float pt = easeOut((float)((in.time - pageSwitchTime_) / 0.22));
    if (pt < 1.f) animating_ = true;
    const float x = 228.f, w = 372.f;
    const float yoff = (1.f - pt) * 10.f;
    cv.globalAlpha = 0.25f + 0.75f * pt;
    label(x, 101.f + yoff, kPageNames[st.page], 21.f, FONT_SEMIBOLD, W(0.96f), -0.2f);
    label(x, 123.f + yoff, kPageDesc[st.page], 12.5f, FONT_REGULAR, W(0.50f));
    const float cy = 142.f + yoff;
    switch (st.page) {
        case 0: pageColors(x, cy, w); break;
        case 1: pageShape(x, cy, w); break;
        case 2: pageMotion(x, cy, w); break;
        case 3: pageEffects(x, cy, w); break;
        default: pageSettings(x, cy, w); break;
    }
    cv.globalAlpha = 1.f;
    restoreClip();

    drawPreview();
    restoreClip();
    drawThemes();
    cv.resetClip();

    // clicking anywhere else cancels a pending key capture
    if (status.capturing != 0 && in.mousePressed && !bindHovered_) out.cancelBind = true;
    bindHovered_ = false;
    // release handling
    if (active_ != 0 && !in.mouseDown) active_ = 0;
    if (in.mousePressed && hot_ == 0) focus_ = 0;
    if (focus_ != 0) animating_ = true;  // caret blink
    lastSettings_ = serializeSettings(st);
}

// ============================================================ sections

void SettingsPanel::drawBackground() {
    Canvas& cv = *cv_;
    const Rc win{0, 0, S(kWidth), S(kHeight)};
    const bool glass = status_->glassBackdrop;
    const float rad = S(8.f);
    // base tint (semi transparent over the OS acrylic blur)
    if (glass && status_->glassLevel >= 2)
        cv.fillRoundRectGrad(win, rad, RGBA{0.075f, 0.075f, 0.105f, 0.56f}, RGBA{0.045f, 0.045f, 0.065f, 0.68f});
    else if (glass)
        cv.fillRoundRectGrad(win, rad, RGBA{0.075f, 0.075f, 0.105f, 0.72f}, RGBA{0.045f, 0.045f, 0.065f, 0.82f});
    else
        cv.fillRoundRectGrad(win, rad, RGBA{0.085f, 0.085f, 0.115f, 0.985f}, RGBA{0.05f, 0.05f, 0.07f, 0.99f});
    // ambient accent light
    cv.glowBlob(S(kWidth * 0.78f), S(-30.f), S(420.f), S(230.f), alpha(accent_, glass ? 0.13f : 0.10f));
    cv.glowBlob(S(80.f), S(kHeight + 40.f), S(380.f), S(220.f), alpha(accentDeep_, glass ? 0.09f : 0.07f));
    // header separator
    cv.fillRect(Rc{S(16.f), S(64.f), S(kWidth - 32.f), std::max(1.f, S(1.f))}, W(0.07f));
    // sidebar separator
    cv.fillRect(Rc{S(212.f), S(80.f), std::max(1.f, S(1.f)), S(kHeight - 96.f)}, W(0.06f));
    // window edge highlight
    cv.strokeRoundRectGrad(win, rad, std::max(1.f, S(1.f)), W(0.16f), W(0.06f));
}

void SettingsPanel::drawHeader() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    // logo tile with the real crosshair
    const Rc tile = R(20.f, 16.f, 32.f, 32.f);
    cv.shadow(tile, S(9.f), S(10.f), Bk(0.45f), S(2.f));
    cv.fillRoundRectGrad(tile, S(9.f), RGBA{0.16f, 0.16f, 0.2f, 0.95f}, RGBA{0.06f, 0.06f, 0.08f, 0.95f});
    cv.strokeRoundRectGrad(tile, S(9.f), std::max(1.f, S(1.f)), W(0.22f), W(0.05f));
    {
        CrosshairStyle ls = st.style;
        ls.scale = 0.42f * s_;
        ls.shadow = 0.f;
        ls.opacity = 1.f;
        logoRenderer_.prepare(ls);
        cv.pushClip(tile.inset(S(1.f)));
        logoRenderer_.render(cv.px, cv.w, cv.h, cv.stride, std::round(tile.cx()), std::round(tile.cy()), -0.3175f, ls,
                             cv.clipX0, cv.clipY0, cv.clipX1, cv.clipY1);
        cv.popClip();
    }
    label(64.f, 31.f, "VORTEX", 15.f, FONT_BOLD, W(0.96f), 3.2f);
    label(64.f, 47.f, "CROSSHAIR OVERLAY", 9.5f, FONT_SEMIBOLD, W(0.42f), 1.6f);

    // status pill: crosshair on/off
    const Rc pill = R(kWidth - 16.f - 34.f - 8.f - 34.f - 10.f - 168.f, 15.f, 168.f, 34.f);
    headerHits_.push_back(pill);
    bool hov = false;
    if (behave(ID("enable-pill"), pill, &hov)) {
        st.enabled = !st.enabled;
        changed();
    }
    const float on = anim(ID("enable-anim"), st.enabled ? 1.f : 0.f, 14.f);
    const float hv = anim(ID("enable-hov"), hov ? 1.f : 0.f, 18.f);
    cv.fillRoundRect(pill, pill.h * 0.5f, W(0.06f + 0.04f * hv));
    cv.strokeRoundRect(pill, pill.h * 0.5f, std::max(1.f, S(1.f)), W(0.10f + 0.05f * hv));
    // status dot with glow
    const float dx = pill.x + S(16.f), dy = pill.cy();
    const RGBA green{0.36f, 1.f, 0.62f, 1}, grey = W(0.35f);
    const RGBA dc = mix(grey, green, on);
    if (on > 0.01f) cv.fillCircle(dx, dy, S(7.5f), alpha(green, 0.16f * on));
    cv.fillCircle(dx, dy, S(3.5f), dc);
    text().drawIn(cv, FONT_SEMIBOLD, S(12.5f), Rc{pill.x + S(28.f), pill.y, S(90.f), pill.h},
                  st.enabled ? "Crosshair on" : "Crosshair off", W(0.88f), 0);
    // mini switch inside the pill (visual only; the whole pill is the button)
    const Rc sw{pill.r() - S(10.f) - S(36.f), pill.cy() - S(10.f), S(36.f), S(20.f)};
    cv.fillRoundRect(sw, sw.h * 0.5f, W(0.14f));
    if (on > 0.001f) {
        RGBA a0 = accentDeep_, a1 = accent_;
        a0.a *= on;
        a1.a *= on;
        cv.fillRoundRectGrad(sw, sw.h * 0.5f, a0, a1, false);
    }
    const float kr = sw.h * 0.5f - S(2.5f);
    cv.fillCircle(sw.x + sw.h * 0.5f + on * (sw.w - sw.h), sw.cy(), kr, W(0.97f));

    // quit (two-step confirm) and hide buttons
    const Rc quitR = R(kWidth - 16.f - 34.f - 8.f - 34.f, 15.f, 34.f, 34.f);
    const Rc closeR = R(kWidth - 16.f - 34.f, 15.f, 34.f, 34.f);
    headerHits_.push_back(quitR);
    headerHits_.push_back(closeR);
    const bool armed = in_.time - armedAt_ < 3.0;
    if (armed) {
        animating_ = true;
        const float a = 0.5f + 0.5f * std::sin((float)in_.time * 8.f);
        cv.fillRoundRect(quitR, S(10.f), RGBA{1.f, 0.3f, 0.34f, 0.25f + 0.2f * a});
        const std::string q = "Click again to quit";
        const float tw = text().measure(FONT_SEMIBOLD, S(11.5f), q);
        const Rc tip{quitR.cx() - tw * 0.5f - S(10.f), quitR.b() + S(8.f), tw + S(20.f), S(26.f)};
        cv.shadow(tip, S(8.f), S(10.f), Bk(0.5f), S(2.f));
        cv.fillRoundRect(tip, S(8.f), RGBA{0.16f, 0.06f, 0.08f, 0.96f});
        cv.strokeRoundRect(tip, S(8.f), std::max(1.f, S(1.f)), RGBA{1.f, 0.4f, 0.45f, 0.5f});
        text().drawIn(cv, FONT_SEMIBOLD, S(11.5f), tip, q, RGBA{1.f, 0.8f, 0.82f, 1.f}, 1);
    }
    if (iconButton(ID("quit"), quitR, IC_POWER)) {
        if (armed)
            out_->quit = true;
        else
            armedAt_ = in_.time;
    }
    if (iconButton(ID("close"), closeR, IC_CLOSE)) out_->hideMenu = true;
}

void SettingsPanel::drawSidebar() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const float x = 16.f, w = 182.f;
    const int icons[5] = {IC_COLORS, IC_SHAPE, IC_MOTION, IC_EFFECTS, IC_SETTINGS};
    const float y0 = 82.f, ih = 40.f, gap = 6.f;
    const float selY = anim(ID("navsel"), y0 + st.page * (ih + gap), 16.f);
    // selection pill
    const Rc sel = R(x, selY, w, ih);
    cv.shadow(sel, S(12.f), S(12.f), Bk(0.30f), S(2.f));
    cv.fillRoundRectGrad(sel, S(12.f), W(0.11f), W(0.06f));
    cv.strokeRoundRectGrad(sel, S(12.f), std::max(1.f, S(1.f)), W(0.16f), W(0.05f));
    const Rc bar = R(x + 1.f, selY + 11.f, 3.f, ih - 22.f);
    cv.fillRoundRect(bar.inset(-S(2.f)), S(3.f), alpha(accent_, 0.25f));
    cv.fillRoundRect(bar, S(1.5f), accent_);
    for (int i = 0; i < 5; ++i) {
        const float y = y0 + i * (ih + gap);
        const Rc r = R(x, y, w, ih);
        bool hov = false;
        if (behave(ID("nav", i), r, &hov) && st.page != i) {
            st.page = i;
            changed();
        }
        const float hv = anim(ID("navh", i), hov ? 1.f : 0.f, 18.f);
        const float isSel = clamp01(1.f - std::fabs(selY - y) / (ih + gap));
        if (hv > 0.01f && st.page != i) cv.fillRoundRect(r, S(12.f), W(0.045f * hv));
        const RGBA ic = mix(W(0.55f + 0.2f * hv), accent_, isSel);
        icon(icons[i], S(x + 24.f), r.cy(), S(16.f), ic);
        text().drawIn(cv, isSel > 0.5f ? FONT_SEMIBOLD : FONT_MEDIUM, S(13.5f), Rc{S(x + 46.f), r.y, S(120.f), r.h},
                      kPageNames[i], W(0.60f + 0.15f * hv + 0.3f * isSel), 0);
    }

    // hotkey hint card
    const Rc hint = R(x, kHeight - 16.f - 112.f, w, 112.f);
    card(hint, 14.f);
    label(x + 16.f, kHeight - 16.f - 112.f + 26.f, "MENU KEY", 9.5f, FONT_SEMIBOLD, W(0.42f), 1.4f);
    const std::string kn = keyName(st.menuKey);
    const float kw = std::max(S(84.f), text().measure(FONT_SEMIBOLD, S(12.5f), kn) + S(28.f));
    keycap(Rc{S(x + 16.f), S(kHeight - 16.f - 112.f + 40.f), kw, S(32.f)}, kn, false);
    label(x + 16.f, kHeight - 16.f - 112.f + 94.f, "Press to show or hide", 11.5f, FONT_REGULAR, W(0.45f));
}

void SettingsPanel::paintPreviewBackground(const Rc& r, int bg) {
    Canvas& cv = *cv_;
    const float rad = S(16.f);
    switch (bg) {
        case 1: {  // scene: dusk sky + ground
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
                    const RGBA a{0.20f, 0.15f, 0.16f, 1}, b{0.07f, 0.06f, 0.07f, 1};
                    const RGBA c = mix(a, b, smooth(t));
                    o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1;
                }
            });
            // sun glow on the horizon
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
        default:  // the reference background
            cv.fillRoundRect(r, rad, RGBA{12 / 255.f, 12 / 255.f, 12 / 255.f, 1});
            break;
    }
}

void SettingsPanel::drawPreview() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const Rc r = R(616.f, 82.f, 288.f, 288.f);
    previewPx_ = r;
    cv.shadow(r, S(16.f), S(22.f), Bk(0.45f), S(6.f));
    paintPreviewBackground(r, st.previewBg);

    // crosshair at true pixel size, magnified by the zoom factor (nearest neighbour)
    const Rc zoomR{r.x + S(12.f), r.b() - S(12.f) - S(28.f), S(108.f), S(28.f)};
    const Rc bgR{r.r() - S(12.f) - S(112.f), r.b() - S(12.f) - S(28.f), S(112.f), S(28.f)};
    bool hovCard = false, heldCard = false;
    if (!hovered(zoomR) && !hovered(bgR)) {
        behave(ID("preview-card"), r, &hovCard, &heldCard);
        if (hovCard) out_->cursor = CURSOR_ARROW;
    }
    const int z = std::max(1, std::min(4, st.previewZoom));
    CrosshairStyle cs = effectiveStyle(st, in_.time);
    // preview click reaction
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
    if (speed > 0.f || st.rainbow || boost > 0.f) previewAnimating_ = true;
    previewRenderer_.render(previewBuf_.data(), bw, bh, bw, (float)(bw / 2), (float)(bh / 2), previewAngle_, cs, 0, 0,
                            1 << 30, 1 << 30, pulseZoom);
    {
        const int sx0 = cv.clipX0, sy0 = cv.clipY0, sx1 = cv.clipX1, sy1 = cv.clipY1;
        const Rc in2 = r.inset(S(2.f));
        cv.setClip(std::max(sx0, (int)std::floor(in2.x)), std::max(sy0, (int)std::floor(in2.y)),
                   std::min(sx1, (int)std::ceil(in2.r())), std::min(sy1, (int)std::ceil(in2.b())));
        const int ox = (int)std::round(r.cx()) - (bw / 2) * z, oy = (int)std::round(r.cy()) - (bh / 2) * z;
        cv.blit(previewBuf_.data(), bw, bh, bw, ox, oy, z);
        cv.setClip(sx0, sy0, sx1, sy1);
    }
    previewAnimating_ = true;  // the LIVE label pulses
    // overlay chrome: label, zoom, background chips
    const bool light = st.previewBg == 2;
    const RGBA chromeBg = light ? Bk(0.10f) : Bk(0.35f);
    const RGBA chromeTx = light ? Bk(0.7f) : W(0.78f);
    {
        const Rc tag{r.x + S(12.f), r.y + S(12.f), S(104.f), S(24.f)};
        cv.fillRoundRect(tag, S(12.f), chromeBg);
        const float pulse = 0.5f + 0.5f * std::sin((float)in_.time * 4.f);
        cv.fillCircle(tag.x + S(12.f), tag.cy(), S(3.f + 1.5f * pulse), alpha(RGBA{1.f, 0.3f, 0.36f, 1}, 0.25f));
        cv.fillCircle(tag.x + S(12.f), tag.cy(), S(3.f), RGBA{1.f, 0.36f, 0.42f, 1});
        text().drawIn(cv, FONT_BOLD, S(9.5f), Rc{tag.x + S(22.f), tag.y, tag.w, tag.h}, "LIVE PREVIEW", chromeTx, 0,
                      S(1.1f));
    }
    // zoom segmented
    {
        const Rc zr = zoomR;
        cv.fillRoundRect(zr, S(9.f), chromeBg);
        const char* zl[3] = {"1\xC3\x97", "2\xC3\x97", "4\xC3\x97"};
        const int zv[3] = {1, 2, 4};
        const float iw = (zr.w - S(4.f)) / 3.f;
        int cur = z == 1 ? 0 : (z == 2 ? 1 : 2);
        const float sx = anim(ID("zoomsel"), (float)cur, 18.f);
        cv.fillRoundRect(Rc{zr.x + S(2.f) + sx * iw, zr.y + S(2.f), iw, zr.h - S(4.f)}, S(7.f),
                         light ? W(0.85f) : W(0.16f));
        for (int i = 0; i < 3; ++i) {
            const Rc c{zr.x + S(2.f) + i * iw, zr.y, iw, zr.h};
            if (behave(ID("zoom", i), c) && st.previewZoom != zv[i]) {
                st.previewZoom = zv[i];
                changed();
            }
            text().drawIn(cv, FONT_SEMIBOLD, S(11.5f), c, zl[i], i == cur ? (light ? Bk(0.85f) : W(0.95f)) : alpha(chromeTx, 0.7f), 1);
        }
    }
    // background chips
    {
        const RGBA chipCols[4] = {RGBA{0.05f, 0.05f, 0.05f, 1}, RGBA{0.62f, 0.45f, 0.55f, 1}, RGBA{0.9f, 0.91f, 0.93f, 1},
                                  RGBA{0.2f, 0.2f, 0.24f, 1}};
        const Rc br = bgR;
        cv.fillRoundRect(br, S(9.f), chromeBg);
        for (int i = 0; i < 4; ++i) {
            const float cx = br.x + S(16.f) + i * S(26.67f), cy = br.cy();
            const Rc hit{cx - S(11.f), br.y, S(22.f), br.h};
            bool hv = false;
            if (behave(ID("pvbg", i), hit, &hv) && st.previewBg != i) {
                st.previewBg = i;
                changed();
            }
            const float sel = anim(ID("pvbgsel", i), st.previewBg == i ? 1.f : 0.f, 16.f);
            if (sel > 0.01f) cv.strokeCircle(cx, cy, S(9.5f), S(1.6f), alpha(light ? Bk(0.7f) : W(0.9f), sel));
            cv.fillCircle(cx, cy, S(6.5f + (hv ? 0.6f : 0.f)), chipCols[i]);
            cv.strokeCircle(cx, cy, S(6.5f), std::max(1.f, S(1.f)), W(0.25f));
            if (i == 3) {
                cv.pushClip(Rc{cx - S(6.f), cy - S(6.f), S(12.f), S(12.f)});
                cv.fillRect(Rc{cx - S(0.5f), cy - S(6.f), S(1.f), S(12.f)}, W(0.5f));
                cv.fillRect(Rc{cx - S(6.f), cy - S(0.5f), S(12.f), S(1.f)}, W(0.5f));
                cv.popClip();
            }
        }
    }
    cv.strokeRoundRectGrad(r, S(16.f), std::max(1.f, S(1.f)), W(0.20f), W(0.06f));
}

void SettingsPanel::drawThemes() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const float x0 = 616.f, y0 = 386.f;
    label(x0 + 2.f, y0 + 10.f, "THEMES", 9.5f, FONT_SEMIBOLD, W(0.42f), 1.4f);
    const int cur = matchPreset(st);
    const float cw = (288.f - 3 * 8.f) / 4.f, ch = 66.f;
    CrosshairStyle chipStyle = st.style;
    chipStyle.scale = 0.58f * s_ * std::min(1.4f, std::max(0.6f, st.style.scale));
    chipStyle.shadow = 0.f;
    chipStyle.opacity = 1.f;
    chipRenderer_.prepare(chipStyle);
    for (int i = 0; i < presetCount() && i < 8; ++i) {
        const int col = i % 4, row = i / 4;
        const Rc r = R(x0 + col * (cw + 8.f), y0 + 20.f + row * (ch + 8.f), cw, ch);
        bool hov = false;
        if (behave(ID("theme", i), r, &hov)) {
            applyPreset(st, i);
            st.rainbow = false;
            changed();
        }
        const float hv = anim(ID("themeh", i), hov ? 1.f : 0.f, 16.f);
        const float sel = anim(ID("themes", i), cur == i ? 1.f : 0.f, 14.f);
        const Rc rr = r.offset(0, -S(2.f) * hv);
        cv.fillRoundRectGrad(rr, S(12.f), RGBA{0.10f, 0.10f, 0.13f, 0.85f + 0.1f * hv}, RGBA{0.05f, 0.05f, 0.07f, 0.9f});
        const ColorPreset& p = preset(i);
        if (sel > 0.01f) {
            cv.shadow(rr, S(12.f), S(12.f), alpha(p.fill, 0.35f * sel), 0.f);
            cv.strokeRoundRect(rr, S(12.f), S(1.5f), alpha(p.fill, 0.9f * sel));
        } else {
            cv.strokeRoundRectGrad(rr, S(12.f), std::max(1.f, S(1.f)), W(0.12f + 0.08f * hv), W(0.04f));
        }
        CrosshairStyle cs = chipStyle;
        cs.fill = p.fill;
        cs.line = p.line;
        cs.dotCol = p.dot;
        cs.glowCol = p.glow;
        if (hov) {
            hoverChipAngle_[i] += in_.dt * 3.0f;
            animating_ = true;
        }
        cv.pushClip(rr.inset(S(1.f)));
        chipRenderer_.render(cv.px, cv.w, cv.h, cv.stride, std::round(rr.cx()), std::round(rr.y + S(27.f)),
                             -0.3175f + hoverChipAngle_[i], cs, cv.clipX0, cv.clipY0, cv.clipX1, cv.clipY1);
        cv.popClip();
        text().drawIn(cv, FONT_SEMIBOLD, S(10.f), Rc{rr.x, rr.b() - S(18.f), rr.w, S(12.f)}, p.name,
                      W(0.55f + 0.35f * std::max(hv, sel)), 1);
    }
    // reset to the original look
    if (button(ID("reset-look"), R(x0, kHeight - 16.f - 40.f, 288.f, 40.f), "Reset to original", 0, IC_RESET)) {
        resetLook(st);
        changed();
        pickLast_ = RGBA{-1, -1, -1, -1};
    }
}

// ============================================================ pages

void SettingsPanel::pageColors(float x, float y, float w) {
    Settings& st = *st_;
    std::vector<std::string> targets = {"Blades", "Outline", "Dot", "Glow"};
    segmented(ID("ctarget"), R(x, y, w, 36.f), targets, st.colorTarget, 12.5f);
    RGBA* cols[4] = {&st.style.fill, &st.style.line, &st.style.dotCol, &st.style.glowCol};
    RGBA& c = *cols[std::max(0, std::min(3, st.colorTarget))];
    card(R(x, y + 48.f, w, 316.f), 16.f);
    colorPicker(x + 16.f, y + 64.f, w - 32.f, c);

    // rainbow row
    const float ry = y + 376.f;
    card(R(x, ry, w, 64.f), 16.f);
    label(x + 16.f, ry + 27.f, "Rainbow cycle", 13.f, FONT_MEDIUM, W(0.88f));
    if (st.rainbow) {
        int sp = st.rainbowSpeed < 0.12f ? 0 : (st.rainbowSpeed < 0.35f ? 1 : 2);
        const int before = sp;
        segmented(ID("rbspeed"), R(x + w - 16.f - 42.f - 14.f - 168.f, ry + 16.f, 168.f, 32.f), {"Slow", "Med", "Fast"}, sp, 11.5f);
        if (sp != before) st.rainbowSpeed = sp == 0 ? 0.08f : (sp == 1 ? 0.2f : 0.55f);
        label(x + 16.f, ry + 45.f, "Hue drifts over time", 11.5f, FONT_REGULAR, W(0.46f));
    } else {
        label(x + 16.f, ry + 45.f, "Cycle every color through the spectrum", 11.5f, FONT_REGULAR, W(0.46f));
    }
    toggle(ID("rainbow"), R(x + w - 16.f - 42.f, ry + 20.f, 42.f, 24.f), st.rainbow);
}

void SettingsPanel::colorPicker(float x, float y, float w, RGBA& color) {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    // sync HSV state when the colour changed elsewhere or the target changed
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
    const Rc sv = R(x, y, w, 146.f);
    bool hovSV = false, heldSV = false;
    behave(ID("sv"), sv, &hovSV, &heldSV);
    if (heldSV) {
        pickS_ = clamp01((in_.mx - sv.x) / sv.w);
        pickV_ = 1.f - clamp01((in_.my - sv.y) / sv.h);
        modified = true;
    }
    const float H = pickH_;
    cv.paintRoundRect(sv, S(12.f), [&](float px, float py, float* o) {
        const float s = clamp01((px - sv.x) / sv.w), v = 1.f - clamp01((py - sv.y) / sv.h);
        const RGBA c = hsvToRgb(H, s, v);
        o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1.f;
    });
    cv.strokeRoundRect(sv, S(12.f), std::max(1.f, S(1.f)), W(0.12f));
    {
        const float kx = sv.x + pickS_ * sv.w, ky = sv.y + (1.f - pickV_) * sv.h;
        const float kr = S(heldSV ? 10.f : 8.5f);
        cv.shadow(Rc{kx - kr, ky - kr, kr * 2, kr * 2}, kr, S(6.f), Bk(0.5f), S(1.f));
        cv.fillCircle(kx, ky, kr, W(1.f));
        cv.fillCircle(kx, ky, kr - S(2.5f), hsvToRgb(pickH_, pickS_, pickV_));
    }

    // hue bar
    const Rc hue = R(x, y + 160.f, w, 14.f);
    bool heldH = false;
    behave(ID("hue"), hue.inset(0, -S(5.f)), nullptr, &heldH);
    if (heldH) {
        pickH_ = clamp01((in_.mx - hue.x) / hue.w) * 0.9999f;
        modified = true;
    }
    cv.paintRoundRect(hue, hue.h * 0.5f, [&](float px, float, float* o) {
        const RGBA c = hsvToRgb(clamp01((px - hue.x) / hue.w) * 0.9999f, 1.f, 1.f);
        o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1.f;
    });
    {
        const float kx = hue.x + pickH_ * hue.w, ky = hue.cy();
        const float kr = S(heldH ? 10.f : 9.f);
        cv.shadow(Rc{kx - kr, ky - kr, kr * 2, kr * 2}, kr, S(6.f), Bk(0.5f), S(1.f));
        cv.fillCircle(kx, ky, kr, W(1.f));
        cv.fillCircle(kx, ky, kr - S(2.5f), hsvToRgb(pickH_, 1.f, 1.f));
    }

    // alpha bar (checkerboard + gradient)
    const Rc al = R(x, y + 186.f, w, 14.f);
    bool heldA = false;
    behave(ID("alpha"), al.inset(0, -S(5.f)), nullptr, &heldA);
    if (heldA) {
        color.a = std::round(clamp01((in_.mx - al.x) / al.w) * 100.f) / 100.f;
        changed();
    }
    const RGBA base = hsvToRgb(pickH_, pickS_, pickV_);
    const float cell = S(5.f);
    cv.paintRoundRect(al, al.h * 0.5f, [&](float px, float py, float* o) {
        const int cx = (int)std::floor((px - al.x) / cell), cy = (int)std::floor((py - al.y) / cell);
        const float chk = ((cx + cy) & 1) ? 0.42f : 0.26f;
        const float t = clamp01((px - al.x) / al.w);
        o[0] = chk + (base.r - chk) * t;
        o[1] = chk + (base.g - chk) * t;
        o[2] = chk + (base.b - chk) * t;
        o[3] = 1.f;
    });
    {
        const float kx = al.x + color.a * al.w, ky = al.cy();
        const float kr = S(heldA ? 10.f : 9.f);
        cv.shadow(Rc{kx - kr, ky - kr, kr * 2, kr * 2}, kr, S(6.f), Bk(0.5f), S(1.f));
        cv.fillCircle(kx, ky, kr, W(1.f));
        cv.fillCircle(kx, ky, kr - S(2.5f), RGBA{base.r, base.g, base.b, 1.f});
    }

    if (modified) {
        const float a = color.a;
        color = hsvToRgb(pickH_, pickS_, pickV_, a);
        changed();
    }

    // value row: swatch, hex field, alpha readout, copy
    const float ry = y + 214.f;
    const Rc sw = R(x, ry, 36.f, 36.f);
    cv.fillRoundRect(sw, S(10.f), W(0.15f));
    cv.fillRoundRect(sw.inset(S(3.f)), S(7.f), RGBA{color.r, color.g, color.b, 1.f});
    cv.strokeRoundRect(sw, S(10.f), std::max(1.f, S(1.f)), W(0.14f));
    hexField(ID("hex"), R(x + 46.f, ry, 122.f, 36.f), color);
    {
        const Rc ar = R(x + 178.f, ry, 62.f, 36.f);
        cv.fillRoundRect(ar, S(10.f), Bk(0.25f));
        cv.strokeRoundRect(ar, S(10.f), std::max(1.f, S(1.f)), W(0.08f));
        text().drawIn(cv, FONT_SEMIBOLD, S(12.5f), ar, fmtInt(color.a * 100.f, "%"), W(0.85f), 1);
    }
    if (button(ID("copyhex"), R(x + 250.f, ry, w - 250.f, 36.f), "Copy", 0, IC_COPY))
        out_->copyText = toHex(color, color.a < 0.999f);

    // swatches
    const float sy = y + 264.f;
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
        const float hv = anim(ID("swh", i), hov ? 1.f : 0.f, 18.f);
        const float rr = S(d * 0.5f) + S(1.5f) * hv;
        if (same) cv.strokeCircle(r.cx(), r.cy(), rr + S(3.5f), S(1.8f), W(0.9f));
        cv.shadow(Rc{r.cx() - rr, r.cy() - rr, rr * 2, rr * 2}, rr, S(6.f), alpha(c, 0.35f * hv), 0.f);
        cv.fillCircle(r.cx(), r.cy(), rr, c);
        cv.strokeCircle(r.cx(), r.cy(), rr - S(0.5f), std::max(1.f, S(1.f)), Bk(0.18f));
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
            if (hexSelectAll_) { hexEdit_.clear(); caret_ = 0; hexSelectAll_ = false; }
            hexEdit_.insert(caret_, p.substr(0, 8 - std::min<size_t>(8, hexEdit_.size())));
            caret_ = std::min(hexEdit_.size(), caret_ + p.size());
            edited = true;
        }
        for (char ch : in_.typed) {
            if (!std::isxdigit((unsigned char)ch)) continue;
            if (hexSelectAll_) { hexEdit_.clear(); caret_ = 0; hexSelectAll_ = false; }
            if (hexEdit_.size() >= 8) continue;
            hexEdit_.insert(hexEdit_.begin() + (long)caret_, (char)std::toupper((unsigned char)ch));
            ++caret_;
            edited = true;
        }
        if (in_.kSelectAll) hexSelectAll_ = true;
        if (in_.kBack) {
            if (hexSelectAll_) { hexEdit_.clear(); caret_ = 0; hexSelectAll_ = false; }
            else if (caret_ > 0) { hexEdit_.erase(caret_ - 1, 1); --caret_; }
            edited = true;
        }
        if (in_.kDelete) {
            if (hexSelectAll_) { hexEdit_.clear(); caret_ = 0; hexSelectAll_ = false; }
            else if (caret_ < hexEdit_.size()) hexEdit_.erase(caret_, 1);
            edited = true;
        }
        if (in_.kLeft && caret_ > 0) { --caret_; hexSelectAll_ = false; }
        if (in_.kRight && caret_ < hexEdit_.size()) { ++caret_; hexSelectAll_ = false; }
        if (in_.kHome) { caret_ = 0; hexSelectAll_ = false; }
        if (in_.kEnd) { caret_ = hexEdit_.size(); hexSelectAll_ = false; }
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
    if (fa > 0.01f) cv.shadow(r, S(10.f), S(10.f), alpha(accent_, 0.45f * fa), 0.f, S(1.f));
    cv.fillRoundRect(r, S(10.f), Bk(0.25f + 0.1f * fa));
    cv.strokeRoundRect(r, S(10.f), std::max(1.f, S(1.f)), mix(W(0.08f + 0.06f * (hov ? 1.f : 0.f)), accent_, fa));
    const std::string shown = focused ? hexEdit_ : toHex(color, false).substr(1);
    const float tx = r.x + S(14.f);
    const float hashW = text().draw(cv, FONT_MEDIUM, S(13.f), tx, r.cy() + text().capHeight(FONT_MEDIUM, S(13.f)) * 0.5f, "#",
                                    W(0.4f));
    const float vx0 = tx + hashW + S(2.f);
    const float baseline = r.cy() + text().capHeight(FONT_SEMIBOLD, S(13.f)) * 0.5f;
    if (focused && hexSelectAll_ && !hexEdit_.empty()) {
        const float sw = text().measure(FONT_SEMIBOLD, S(13.f), hexEdit_, S(0.6f));
        cv.fillRoundRect(Rc{vx0 - S(2.f), r.cy() - S(10.f), sw + S(4.f), S(20.f)}, S(4.f), alpha(accent_, 0.35f));
    }
    text().draw(cv, FONT_SEMIBOLD, S(13.f), vx0, baseline, shown, W(0.92f), S(0.6f));
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
    card(R(x, y, w, 336.f), 16.f);
    const float ix = x + 16.f, iw = w - 32.f;
    float yy = y + 14.f;
    sliderRow(ID("scale"), ix, yy, iw, "Size", fmtInt(c.scale * 100.f, "%"), c.scale, 0.5f, 4.f, 0.05f);
    yy += 53.f;
    sliderRow(ID("length"), ix, yy, iw, "Blade length", fmt1(c.length, " px"), c.length, 6.f, 60.f, 0.1f);
    yy += 53.f;
    sliderRow(ID("width"), ix, yy, iw, "Blade width", fmt1(c.width, " px"), c.width, 2.f, 24.f, 0.1f);
    yy += 53.f;
    sliderRow(ID("gap"), ix, yy, iw, "Center gap", fmt1(c.gap, " px"), c.gap, 0.f, 30.f, 0.1f);
    yy += 53.f;
    {
        // outline thickness with an inline on/off switch
        label(ix, yy + 14.f, "Outline", 13.f, FONT_MEDIUM, W(0.86f));
        toggle(ID("outline-on"), R(ix + 62.f, yy + 3.f, 32.f, 18.f), c.showOutline);
        const std::string v = c.showOutline ? fmt1(c.outline, " px") : std::string("Off");
        const float vw = text().measure(FONT_SEMIBOLD, S(12.f), v);
        const Rc pill{S(ix + iw) - vw - S(16.f), S(yy + 1.f), vw + S(16.f), S(20.f)};
        cv_->fillRoundRect(pill, S(6.f), W(0.06f));
        text().drawIn(*cv_, FONT_SEMIBOLD, S(12.f), pill, v, accentText_, 1);
        const float ga = cv_->globalAlpha;
        if (!c.showOutline) cv_->globalAlpha = ga * 0.4f;
        slider(ID("outline"), R(ix, yy + 26.f, iw, 20.f), c.outline, 0.f, 4.f, 0.05f);
        cv_->globalAlpha = ga;
    }
    yy += 53.f;
    sliderRow(ID("dot"), ix, yy, iw, "Center dot", c.dot > 0.01f ? fmt1(c.dot, " px") : std::string("Off"), c.dot, 0.f, 6.f,
              0.05f);

    const float by = y + 348.f;
    card(R(x, by, w, 66.f), 16.f);
    label(ix, by + 38.f, "Blades", 13.f, FONT_MEDIUM, W(0.86f));
    static const int counts[6] = {2, 3, 4, 5, 6, 8};
    int sel = 2;
    for (int i = 0; i < 6; ++i)
        if (counts[i] == c.blades) sel = i;
    if (segmented(ID("blades"), R(ix + 76.f, by + 15.f, iw - 76.f, 36.f), {"2", "3", "4", "5", "6", "8"}, sel, 12.5f))
        c.blades = counts[sel];
}

void SettingsPanel::pageMotion(float x, float y, float w) {
    Settings& st = *st_;
    const float ix = x + 16.f, iw = w - 32.f;
    card(R(x, y, w, 238.f), 16.f);
    float yy = y + 10.f;
    toggleRow(ID("spin"), ix, yy, iw, "Spin", "Rotate the crosshair continuously", st.spin);
    yy += 56.f;
    char v[48];
    std::snprintf(v, sizeof(v), "%d\xC2\xB0/s  \xC2\xB7  %.2f rps", (int)std::lround(st.spinSpeed), st.spinSpeed / 360.f);
    const float ga = cv_->globalAlpha;
    if (!st.spin) cv_->globalAlpha = ga * 0.45f;
    sliderRow(ID("speed"), ix, yy, iw, "Speed", v, st.spinSpeed, 0.f, 1080.f, 5.f);
    yy += 56.f;
    {
        static const float speeds[4] = {60.f, 150.f, 360.f, 720.f};
        static const char* names[4] = {"Chill", "Smooth", "Fast", "Turbo"};
        const float cw = (iw - 3 * 8.f) / 4.f;
        for (int i = 0; i < 4; ++i) {
            const Rc r = R(ix + i * (cw + 8.f), yy, cw, 30.f);
            bool hov = false;
            if (behave(ID("spdchip", i), r, &hov)) {
                st.spinSpeed = speeds[i];
                st.spin = true;
                changed();
            }
            const bool on = std::fabs(st.spinSpeed - speeds[i]) < 0.5f;
            const float hv = anim(ID("spdchiph", i), hov ? 1.f : 0.f, 18.f);
            cv_->fillRoundRect(r, S(9.f), on ? alpha(accent_, 0.18f) : W(0.05f + 0.04f * hv));
            cv_->strokeRoundRect(r, S(9.f), std::max(1.f, S(1.f)), on ? alpha(accent_, 0.65f) : W(0.09f + 0.05f * hv));
            text().drawIn(*cv_, FONT_SEMIBOLD, S(12.f), r, names[i], on ? accentText_ : W(0.7f + 0.2f * hv), 1);
        }
    }
    yy += 44.f;
    label(ix, yy + 22.f, "Direction", 13.f, FONT_MEDIUM, W(0.86f));
    segmented(ID("dir"), R(ix + 96.f, yy + 4.f, iw - 96.f, 34.f), {"Clockwise", "Counter"}, st.spinDir, 12.5f);
    cv_->globalAlpha = ga;

    const float cy = y + 250.f;
    card(R(x, cy, w, 120.f), 16.f);
    label(ix, cy + 28.f, "Click reaction", 13.f, FONT_MEDIUM, W(0.88f));
    label(ix, cy + 46.f, "React while a mouse button is held. Try it on the preview.", 11.5f, FONT_REGULAR, W(0.46f));
    segmented(ID("react"), R(ix, cy + 64.f, iw, 36.f), {"None", "Spin boost", "Pulse"}, st.clickReact, 12.5f);
}

void SettingsPanel::pageEffects(float x, float y, float w) {
    Settings& st = *st_;
    CrosshairStyle& c = st.style;
    const float ix = x + 16.f, iw = w - 32.f;
    card(R(x, y, w, 284.f), 16.f);
    float yy = y + 14.f;
    float g = c.glow * 100.f, gs = c.glowSize * 100.f, h = c.halo * 100.f, sh = c.shadow * 100.f, op = c.opacity * 100.f;
    sliderRow(ID("glow"), ix, yy, iw, "Glow strength", fmtInt(g, "%"), g, 0.f, 250.f, 1.f);
    yy += 53.f;
    sliderRow(ID("glowsize"), ix, yy, iw, "Glow spread", fmtInt(gs, "%"), gs, 50.f, 300.f, 1.f);
    yy += 53.f;
    sliderRow(ID("halo"), ix, yy, iw, "Dot halo", fmtInt(h, "%"), h, 0.f, 300.f, 1.f);
    yy += 53.f;
    sliderRow(ID("shadow"), ix, yy, iw, "Contrast shadow", sh < 0.5f ? std::string("Off") : fmtInt(sh, "%"), sh, 0.f, 100.f, 1.f);
    yy += 53.f;
    sliderRow(ID("opacity"), ix, yy, iw, "Opacity", fmtInt(op, "%"), op, 10.f, 100.f, 1.f);
    c.glow = g / 100.f;
    c.glowSize = gs / 100.f;
    c.halo = h / 100.f;
    c.shadow = sh / 100.f;
    c.opacity = op / 100.f;

    const float ty = y + 296.f;
    card(R(x, ty, w, 78.f), 16.f);
    icon(IC_TARGET, S(ix + 9.f), S(ty + 39.f), S(18.f), accent_);
    label(ix + 30.f, ty + 33.f, "Tip", 12.5f, FONT_SEMIBOLD, accentText_);
    label(ix + 30.f, ty + 51.f, "Bright game? Add a little contrast shadow so the", 11.5f, FONT_REGULAR, W(0.55f));
    label(ix + 30.f, ty + 66.f, "white outline stays readable on snow and sky.", 11.5f, FONT_REGULAR, W(0.55f));
}

void SettingsPanel::pageSettings(float x, float y, float w) {
    Settings& st = *st_;
    const float ix = x + 16.f, iw = w - 32.f;
    // placement
    card(R(x, y, w, 132.f), 16.f);
    label(ix, y + 26.f, "Position", 13.f, FONT_MEDIUM, W(0.88f));
    segmented(ID("pos"), R(ix + 90.f, y + 10.f, iw - 90.f, 34.f), {"Follow cursor", "Screen center"}, st.position, 12.5f);
    {
        float ox = (float)st.offsetX, oy = (float)st.offsetY;
        const float hw = (iw - 16.f) / 2.f;
        sliderRow(ID("offx"), ix, y + 58.f, hw, "Nudge X", fmtInt(ox, " px"), ox, -50.f, 50.f, 1.f);
        sliderRow(ID("offy"), ix + hw + 16.f, y + 58.f, hw, "Nudge Y", fmtInt(oy, " px"), oy, -50.f, 50.f, 1.f);
        st.offsetX = (int)std::lround(ox);
        st.offsetY = (int)std::lround(oy);
    }
    // toggles
    const float ty = y + 144.f;
    card(R(x, ty, w, 164.f), 16.f);
    toggleRow(ID("hidecur"), ix, ty + 6.f, iw, "Hide Windows cursor", "The crosshair becomes your pointer", st.hideCursor);
    cv_->fillRect(R(ix, ty + 56.f, iw, 1.f), W(0.06f));
    toggleRow(ID("hidecap"), ix, ty + 58.f, iw, "Hide from screen capture", "Invisible to OBS, Discord and screenshots",
              st.hideFromCapture);
    cv_->fillRect(R(ix, ty + 108.f, iw, 1.f), W(0.06f));
    toggleRow(ID("autostart"), ix, ty + 110.f, iw, "Start with Windows", "Launch quietly in the tray", st.startWithWindows);
    // hotkeys
    const float ky = y + 320.f;
    card(R(x, ky, w, 104.f), 16.f);
    auto bindRow = [&](int which, float yy, const char* name, int vk) {
        label(ix, yy + 22.f, name, 13.f, FONT_MEDIUM, W(0.88f));
        const bool cap = status_->capturing == which;
        const std::string kn = cap ? std::string("Press a key\xE2\x80\xA6") : keyName(vk);
        const float kw = std::max(S(96.f), text().measure(FONT_SEMIBOLD, S(12.5f), kn) + S(30.f));
        const Rc kr{S(ix + iw) - kw, S(yy + 4.f), kw, S(30.f)};
        bool hov = false;
        if (behave(ID("bind", which), kr, &hov)) {
            if (cap) out_->cancelBind = true;
            else out_->bindKey = which;
        }
        if (hov) bindHovered_ = true;
        if (cap) animating_ = true;
        keycap(kr.offset(0, hov ? -S(1.f) : 0.f), kn, cap);
        if (which == 2 && vk != 0 && !cap) {
            const Rc clr{kr.x - S(34.f), kr.y, S(30.f), S(30.f)};
            if (iconButton(ID("bindclr"), clr, IC_CLOSE)) out_->clearToggleKey = true;
        }
    };
    bindRow(1, ky + 12.f, "Menu key", st.menuKey);
    cv_->fillRect(R(ix, ky + 52.f, iw, 1.f), W(0.06f));
    bindRow(2, ky + 58.f, "Show / hide crosshair", st.toggleKey);
}

}  // namespace vx
