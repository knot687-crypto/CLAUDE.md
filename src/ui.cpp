// Vortex Crosshair - settings panel (immediate mode, software rendered)
//
// Design notes: a quiet, neutral dark surface; the crosshair on a large stage is
// the only colourful element. Hairline borders, one radius family, sentence-case
// labels, monochrome controls and short, critically damped motion. Opening the
// menu plays a short sequence: the crosshair assembles on the stage while the
// settings rows fade in one after another.
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
inline float easeOut3(float t) { t = clamp01(t); return 1.f - (1.f - t) * (1.f - t) * (1.f - t); }
inline float easeOut5(float t) {
    t = clamp01(t);
    const float u = 1.f - t;
    return 1.f - u * u * u * u * u;
}

inline RGBA W(float a) { return RGBA{1, 1, 1, a}; }
inline RGBA Bk(float a) { return RGBA{0, 0, 0, a}; }

// layout (DIPs)
constexpr float kStageX = 16.f, kStageY = 56.f, kStageW = 464.f, kStageH = 568.f;
constexpr float kInsX = 496.f, kInsW = 448.f;
constexpr float kTabsY = 56.f;
constexpr float kContentY = 116.f;
constexpr float kRowH = 46.f;

enum Icon { IC_CLOSE, IC_POWER, IC_RESET, IC_COPY, IC_CHECK };

const char* kTabs[5] = {"Style", "Shape", "Motion", "Effects", "General"};
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
    if (std::fabs(target - sp.x) < 0.001f && std::fabs(sp.v) < 0.01f) {
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
    }
    if (active_ == id && in_.mouseReleased && hovered(r)) clicked = true;
    if (hover) *hover = over;
    if (held) *held = active_ == id && in_.mouseDown;
    if (over) out_->cursor = CURSOR_HAND;
    return clicked;
}

void SettingsPanel::text(float x, float y, const std::string& t, float size, int face, const RGBA& c,
                         float tracking) {
    vx::text().draw(*cv_, face, S(size), S(x), S(y), t, c, S(tracking));
}

void SettingsPanel::resetInteraction() {
    active_ = 0;
    hot_ = 0;
    focus_ = 0;
    tipId_ = 0;
}

bool SettingsPanel::dragArea(float x, float y) const {
    if (y < 0 || y > S(52.f)) return false;
    for (const Rc& r : headerHits_)
        if (r.contains(x, y)) return false;
    return true;
}

float SettingsPanel::beginRow() {
    // rows cascade in after the menu opens or the page changes
    const double start = std::max(openTime_ + 0.16, pageSwitchTime_);
    const bool pageSwitch = pageSwitchTime_ > openTime_ + 0.16;
    const float stagger = pageSwitch ? 0.014f : 0.024f, dur = pageSwitch ? 0.22f : 0.34f;
    const float t = (since(start) - rowIndex_ * stagger) / dur;
    ++rowIndex_;
    const float e = easeOut3(t);
    if (t < 1.f) animating_ = true;
    rowAlpha_ = e;
    cv_->globalAlpha = sectionAlpha_ * e;
    return (1.f - e) * (pageSwitch ? 5.f : 9.f);
}

void SettingsPanel::endRow() { cv_->globalAlpha = sectionAlpha_; }

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
    const float t = (since(tipStart_) - 0.45f) / 0.12f;
    if (t < 1.f) animating_ = true;
    if (t <= 0.f) return;
    Canvas& cv = *cv_;
    const float fs = S(12.f);
    const float tw = vx::text().measure(FONT_MEDIUM, fs, tipText_);
    Rc tip{tipAnchor_.cx() - tw * 0.5f - S(9.f), tipAnchor_.b() + S(6.f), tw + S(18.f), S(26.f)};
    tip.x = std::max(S(8.f), std::min(tip.x, (float)cv.w - tip.w - S(8.f)));
    if (tip.b() > (float)cv.h - S(6.f)) tip.y = tipAnchor_.y - S(6.f) - tip.h;
    const float ga = cv.globalAlpha;
    cv.globalAlpha = smooth(t);
    cv.shadow(tip, S(6.f), S(10.f), Bk(0.45f), S(3.f));
    cv.fillRoundRect(tip, S(6.f), RGBA{0.11f, 0.11f, 0.12f, 0.98f});
    cv.strokeRoundRect(tip, S(6.f), px1(), W(0.10f));
    vx::text().drawIn(cv, FONT_MEDIUM, fs, tip, tipText_, W(0.88f), 1);
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

void SettingsPanel::group(float x, float y, float w, float h) {
    const Rc r = R(x, y, w, h);
    cv_->fillRoundRect(r, S(12.f), W(0.032f));
    cv_->strokeRoundRect(r, S(12.f), px1(), W(0.065f));
}

void SettingsPanel::separator(float x, float y, float w) { cv_->fillRect(Rc{S(x), S(y), S(w), px1()}, W(0.055f)); }

void SettingsPanel::sectionTitle(float x, float y, const std::string& t) {
    text(x, y, t, 12.f, FONT_SEMIBOLD, W(0.46f));
}

bool SettingsPanel::toggle(uint32_t id, const Rc& r, bool& v) {
    bool hov = false;
    const bool clicked = behave(id, r.inset(-S(4)), &hov);
    if (clicked) {
        v = !v;
        changed();
    }
    Canvas& cv = *cv_;
    const float t = clamp01(spring(id, v ? 1.f : 0.f, 420.f, 41.f));
    const float hv = anim(id ^ 0x55u, hov ? 1.f : 0.f, 18.f);
    const float h = r.h;
    // monochrome: white track when on, quiet grey when off
    cv.fillRoundRect(r, h * 0.5f, mix(W(0.13f + 0.04f * hv), W(0.92f), t));
    const float kr = h * 0.5f - S(2.f);
    const float kx = r.x + h * 0.5f + t * (r.w - h);
    const Rc kb{kx - kr, r.cy() - kr, kr * 2, kr * 2};
    cv.shadow(kb, kr, S(4.f), Bk(0.35f), S(1.f));
    cv.fillCircle(kx, r.cy(), kr, mix(RGBA{0.86f, 0.86f, 0.88f, 1}, RGBA{0.07f, 0.07f, 0.08f, 1}, t));
    return clicked;
}

bool SettingsPanel::slider(uint32_t id, const Rc& r, float& v, float lo, float hi, float step) {
    bool hov = false, held = false;
    behave(id, r.inset(0, -S(6)), &hov, &held);
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
    float t = anim(id ^ 0x3Bu, tv, 26.f);  // glide for wheel / presets / reset
    if (held) {
        t = tv;
        anim_[id ^ 0x3Bu] = tv;
    }
    const float cy = r.cy();
    const float th = S(4.f);
    const float hv = anim(id ^ 0x77u, (hov || held) ? 1.f : 0.f, 20.f);
    cv.fillRoundRect(Rc{r.x, cy - th * 0.5f, r.w, th}, th * 0.5f, W(0.12f + 0.03f * hv));
    cv.fillRoundRect(Rc{r.x, cy - th * 0.5f, std::max(th, r.w * t), th}, th * 0.5f, W(0.88f));
    const float kx = r.x + r.w * t;
    const float kr = S(7.f) + S(1.f) * hv + S(1.f) * anim(id ^ 0x99u, held ? 1.f : 0.f, 24.f);
    const Rc kb{kx - kr, cy - kr, kr * 2, kr * 2};
    cv.shadow(kb, kr, S(6.f), Bk(0.45f), S(1.f));
    cv.fillCircle(kx, cy, kr, W(1.f));
    return ch;
}

bool SettingsPanel::segmented(uint32_t id, const Rc& r, const std::vector<std::string>& items, int& sel) {
    const int n = (int)items.size();
    if (n == 0) return false;
    Canvas& cv = *cv_;
    const float rad = S(8.f);
    cv.fillRoundRect(r, rad, W(0.055f));
    const float iw = (r.w - S(4.f)) / n;
    if (sel >= 0) {
        const float sx = spring(id, (float)sel, 420.f, 41.f);
        const Rc pill{r.x + S(2.f) + sx * iw, r.y + S(2.f), iw, r.h - S(4.f)};
        cv.shadow(pill, S(6.f), S(4.f), Bk(0.30f), S(1.f));
        cv.fillRoundRect(pill, S(6.f), RGBA{0.25f, 0.25f, 0.27f, 1.f});
        cv.strokeRoundRectGrad(pill, S(6.f), px1(), W(0.12f), W(0.03f));
    }
    bool changedSel = false;
    for (int i = 0; i < n; ++i) {
        const Rc cell{r.x + S(2.f) + i * iw, r.y, iw, r.h};
        bool hov = false;
        if (behave(id + 1 + i, cell, &hov) && sel != i) {
            sel = i;
            changedSel = true;
            changed();
        }
        const float hv = anim((id + 1 + i) ^ 0x31u, hov ? 1.f : 0.f, 20.f);
        const bool on = sel == i;
        vx::text().drawIn(cv, FONT_MEDIUM, S(12.f), cell, items[i], W(on ? 0.95f : 0.52f + 0.22f * hv), 1);
    }
    return changedSel;
}

bool SettingsPanel::ghostButton(uint32_t id, const Rc& r, const std::string& t, int ic) {
    bool hov = false, held = false;
    const bool clicked = behave(id, r, &hov, &held);
    Canvas& cv = *cv_;
    const float hv = anim(id, hov ? 1.f : 0.f, 20.f);
    const float rad = S(8.f);
    cv.fillRoundRect(r, rad, W(0.03f + 0.045f * hv - (held ? 0.02f : 0.f)));
    cv.strokeRoundRect(r, rad, px1(), W(0.10f + 0.05f * hv));
    const RGBA tc = W(0.70f + 0.22f * hv);
    const float fs = S(12.5f);
    const float tw = vx::text().measure(FONT_MEDIUM, fs, t);
    float x = r.cx() - tw * 0.5f;
    if (ic >= 0) {
        const float isz = S(12.f);
        x += (isz + S(7.f)) * 0.5f;
        icon(ic, x - S(7.f) - isz * 0.5f, r.cy(), isz, tc);
    }
    vx::text().draw(cv, FONT_MEDIUM, fs, x, r.cy() + vx::text().capHeight(FONT_MEDIUM, fs) * 0.5f, t, tc);
    return clicked;
}

bool SettingsPanel::iconButton(uint32_t id, const Rc& r, int ic, const std::string& tip, bool danger) {
    bool hov = false, held = false;
    const bool clicked = behave(id, r, &hov, &held);
    Canvas& cv = *cv_;
    const float hv = anim(id, hov ? 1.f : 0.f, 20.f);
    if (hv > 0.01f)
        cv.fillRoundRect(r, S(8.f), danger ? RGBA{1.f, 0.30f, 0.30f, 0.16f * hv} : W(0.07f * hv + (held ? 0.03f : 0.f)));
    icon(ic, r.cx(), r.cy(), S(14.f), danger && hv > 0.5f ? RGBA{1.f, 0.62f, 0.62f, 1.f} : W(0.55f + 0.37f * hv));
    if (!tip.empty()) tooltip(id, r, tip);
    return clicked;
}

void SettingsPanel::keycap(const Rc& r, const std::string& t, bool active, bool small) {
    Canvas& cv = *cv_;
    const float rad = S(small ? 5.f : 7.f);
    cv.fillRoundRect(r.offset(0, S(1.5f)), rad, Bk(0.45f));
    cv.fillRoundRect(r, rad, active ? W(0.90f) : RGBA{0.17f, 0.17f, 0.18f, 1.f});
    if (!active) cv.strokeRoundRectGrad(r, rad, px1(), W(0.14f), W(0.05f));
    vx::text().drawIn(cv, FONT_MEDIUM, S(small ? 11.f : 12.f), r, t, active ? RGBA{0.06f, 0.06f, 0.07f, 1} : W(0.86f), 1);
}

void SettingsPanel::icon(int which, float cx, float cy, float size, const RGBA& c) {
    const float u = size / 16.f;
    const float lw = std::max(1.1f, 1.45f * u);
    Canvas& cv = *cv_;
    switch (which) {
        case IC_CLOSE: {
            const float d = 4.4f * u;
            cv.line(cx - d, cy - d, cx + d, cy + d, lw, c);
            cv.line(cx + d, cy - d, cx - d, cy + d, lw, c);
            break;
        }
        case IC_POWER:
            cv.arc(cx, cy + 0.6f * u, 5.4f * u, -kPi * 0.5f + 0.62f, kPi * 1.5f - 0.62f, lw, c);
            cv.line(cx, cy - 6.2f * u, cx, cy - 0.8f * u, lw, c);
            break;
        case IC_RESET: {
            cv.arc(cx, cy, 5.2f * u, -kPi * 0.45f, kPi * 1.25f, lw, c);
            const float ex = cx + std::cos(-kPi * 0.45f) * 5.2f * u, ey = cy + std::sin(-kPi * 0.45f) * 5.2f * u;
            const float tri[6] = {ex + 3.0f * u, ey - 0.4f * u, ex - 1.5f * u, ey - 3.0f * u, ex - 0.9f * u, ey + 2.5f * u};
            cv.fillPoly(tri, 3, c);
            break;
        }
        case IC_COPY:
            cv.strokeRoundRect(Rc{cx - 3.f * u, cy - 3.f * u, 8.5f * u, 8.5f * u}, 2.f * u, lw, c);
            cv.strokeRoundRect(Rc{cx - 5.5f * u, cy - 5.5f * u, 8.5f * u, 8.5f * u}, 2.f * u, lw, alpha(c, 0.55f));
            break;
        case IC_CHECK:
            cv.line(cx - 4.6f * u, cy + 0.2f * u, cx - 1.4f * u, cy + 3.6f * u, lw * 1.1f, c);
            cv.line(cx - 1.4f * u, cy + 3.6f * u, cx + 5.f * u, cy - 3.8f * u, lw * 1.1f, c);
            break;
        default: break;
    }
}

void SettingsPanel::sliderRow(uint32_t id, float x, float y, float w, const std::string& name, const std::string& value,
                              float& v, float lo, float hi, float step) {
    text(x + 16.f, y + kRowH * 0.5f + 4.5f, name, 13.f, FONT_MEDIUM, W(0.86f));
    vx::text().drawIn(*cv_, FONT_MEDIUM, S(12.5f), R(x + w - 16.f - 56.f, y, 56.f, kRowH), value, W(0.50f), 2);
    slider(id, R(x + 148.f, y + kRowH * 0.5f - 11.f, w - 148.f - 16.f - 68.f, 22.f), v, lo, hi, step);
}

void SettingsPanel::toggleRow(uint32_t id, float x, float y, float w, const std::string& name, bool& v) {
    text(x + 16.f, y + kRowH * 0.5f + 4.5f, name, 13.f, FONT_MEDIUM, W(0.86f));
    toggle(id, R(x + w - 16.f - 38.f, y + kRowH * 0.5f - 11.f, 38.f, 22.f), v);
}

void SettingsPanel::segmentRow(uint32_t id, float x, float y, float w, const std::string& name,
                               const std::vector<std::string>& items, int& sel, float segW) {
    text(x + 16.f, y + kRowH * 0.5f + 4.5f, name, 13.f, FONT_MEDIUM, W(0.86f));
    segmented(id, R(x + w - 16.f - segW, y + kRowH * 0.5f - 14.f, segW, 28.f), items, sel);
}

// ============================================================ frame

void SettingsPanel::frame(Canvas& cv, float scale, const UIInput& in, Settings& st, UIActions& out,
                          const AppStatus& status) {
    vx::text().init();
    cv_ = &cv;
    s_ = scale;
    in_ = in;
    out_ = &out;
    st_ = &st;
    status_ = &status;
    out.cursor = CURSOR_ARROW;
    headerHits_.clear();
    tipWanted_ = false;

    // full redraw vs cheap stage-only redraw
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

    buildBackground();
    cv.globalAlpha = 1.f;
    const Rc stage = R(kStageX, kStageY, kStageW, kStageH);
    if (full) {
        cv.resetClip();
        for (int y = 0; y < cv.h; ++y)
            std::memcpy(cv.px + (size_t)y * cv.stride, bgCache_.data() + (size_t)y * cv.w, (size_t)cv.w * 4);
        dirty_ = Rc{0, 0, (float)cv.w, (float)cv.h};
    } else {
        cv.setClip(stage);
        for (int y = cv.clipY0; y < cv.clipY1; ++y)
            std::memcpy(cv.px + (size_t)y * cv.stride + cv.clipX0, bgCache_.data() + (size_t)y * cv.w + cv.clipX0,
                        (size_t)(cv.clipX1 - cv.clipX0) * 4);
        dirty_ = Rc{(float)cv.clipX0, (float)cv.clipY0, (float)(cv.clipX1 - cv.clipX0), (float)(cv.clipY1 - cv.clipY0)};
    }
    const int fx0 = cv.clipX0, fy0 = cv.clipY0, fx1 = cv.clipX1, fy1 = cv.clipY1;
    auto restoreClip = [&]() { cv.setClip(fx0, fy0, fx1, fy1); };
    const float t = since(openTime_);
    if (t < 1.4f) animating_ = true;

    sectionAlpha_ = easeOut3(t / 0.30f);
    cv.globalAlpha = sectionAlpha_;
    drawTopBar();
    restoreClip();

    sectionAlpha_ = easeOut3((t - 0.02f) / 0.35f);
    cv.globalAlpha = sectionAlpha_;
    drawStage();
    restoreClip();

    sectionAlpha_ = easeOut3((t - 0.10f) / 0.35f);
    cv.globalAlpha = sectionAlpha_;
    drawTabs();
    restoreClip();

    // page content: rows cascade in (on open and on page change)
    if (st.page != prevPage_) {
        pageSwitchTime_ = in.time;
        prevPage_ = st.page;
        focus_ = 0;
    }
    rowIndex_ = 0;
    const float pageFade = easeOut3(since(pageSwitchTime_) / 0.18f);
    if (pageFade < 1.f) animating_ = true;
    sectionAlpha_ = pageFade;
    cv.globalAlpha = pageFade;
    switch (st.page) {
        case 0: pageStyle(kInsX, kContentY, kInsW); break;
        case 1: pageShape(kInsX, kContentY, kInsW); break;
        case 2: pageMotion(kInsX, kContentY, kInsW); break;
        case 3: pageEffects(kInsX, kContentY, kInsW); break;
        default: pageGeneral(kInsX, kContentY, kInsW); break;
    }
    restoreClip();

    sectionAlpha_ = easeOut3((t - 0.30f) / 0.35f);
    cv.globalAlpha = sectionAlpha_;
    drawFooter();
    restoreClip();
    sectionAlpha_ = 1.f;
    cv.globalAlpha = 1.f;
    drawTooltip();
    cv.resetClip();

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
    char keyBuf[96];
    std::snprintf(keyBuf, sizeof(keyBuf), "%d %d %.3f %d %d", cv.w, cv.h, s_, status_->glassLevel,
                  (int)status_->glassBackdrop);
    if (bgKey_ == keyBuf && bgCache_.size() == (size_t)cv.w * cv.h) return;
    bgKey_ = keyBuf;
    bgCache_.assign((size_t)cv.w * cv.h, 0u);
    Canvas bg;
    bg.attach(bgCache_.data(), cv.w, cv.h, cv.w);
    const Rc win{0, 0, S(kWidth), S(kHeight)};
    const float rad = S(8.f);
    const int level = status_->glassBackdrop ? status_->glassLevel : 0;
    // neutral surface; over the OS acrylic only a hint of blur shows through
    float a = 0.99f;
    if (level >= 2)
        a = 0.86f;
    else if (level == 1)
        a = 0.93f;
    bg.fillRoundRectGrad(win, rad, RGBA{0.078f, 0.078f, 0.086f, a}, RGBA{0.062f, 0.062f, 0.068f, a});
    // a whisper of light along the top edge, then the window hairline
    bg.paintRoundRect(Rc{rad, px1(), win.w - 2 * rad, px1()}, 0.f, [&](float x, float, float* o) {
        const float s = std::sin(clamp01(x / win.w) * kPi);
        o[0] = o[1] = o[2] = 1.f;
        o[3] = 0.10f * s;
    });
    bg.strokeRoundRectGrad(win, rad, px1(), W(0.11f), W(0.06f));
}

void SettingsPanel::drawTopBar() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    // brand: the crosshair itself + wordmark
    {
        CrosshairStyle ls = st.style;
        ls.scale = 0.40f * s_;
        ls.shadow = 0.f;
        ls.opacity = cv.globalAlpha;
        logoRenderer_.prepare(ls);
        const Rc lr = R(16.f, 12.f, 32.f, 32.f);
        cv.pushClip(lr);
        logoRenderer_.render(cv.px, cv.w, cv.h, cv.stride, std::round(lr.cx()), std::round(lr.cy()), -0.3175f, ls,
                             cv.clipX0, cv.clipY0, cv.clipX1, cv.clipY1);
        cv.popClip();
    }
    text(54.f, 33.f, "Vortex", 15.f, FONT_SEMIBOLD, W(0.94f), -0.1f);
    const float vw = vx::text().measure(FONT_SEMIBOLD, S(15.f), "Vortex", S(-0.1f));
    vx::text().draw(cv, FONT_REGULAR, S(13.f), S(54.f) + vw + S(8.f), S(33.f), "Crosshair", W(0.38f));

    // overlay switch, quit, close
    const Rc closeR = R(kWidth - 16.f - 32.f, 12.f, 32.f, 32.f);
    const Rc quitR = R(kWidth - 16.f - 32.f - 4.f - 32.f, 12.f, 32.f, 32.f);
    const Rc sw = R(kWidth - 16.f - 32.f - 4.f - 32.f - 20.f - 38.f, 17.f, 38.f, 22.f);
    const float lw = vx::text().measure(FONT_MEDIUM, S(12.5f), "Overlay");
    const Rc labelHit{sw.x - lw - S(12.f), sw.y - S(5.f), lw + S(8.f), sw.h + S(10.f)};
    headerHits_.push_back(Rc{labelHit.x, labelHit.y, sw.r() - labelHit.x + S(4.f), labelHit.h});
    headerHits_.push_back(quitR);
    headerHits_.push_back(closeR);
    if (behave(ID("overlay-label"), labelHit)) {
        st.enabled = !st.enabled;
        changed();
    }
    vx::text().drawIn(cv, FONT_MEDIUM, S(12.5f), Rc{sw.x - lw - S(10.f), sw.y, lw, sw.h}, "Overlay",
                      W(st.enabled ? 0.80f : 0.48f), 0);
    toggle(ID("overlay"), sw, st.enabled);

    const bool armed = in_.time - armedAt_ < 3.0;
    if (iconButton(ID("quit"), quitR, IC_POWER, armed ? std::string() : std::string("Quit Vortex"), true)) {
        if (armed)
            out_->quit = true;
        else
            armedAt_ = in_.time;
    }
    if (armed) {
        animating_ = true;
        const std::string q = "Click again to quit";
        const float fs = S(12.f);
        const float tw = vx::text().measure(FONT_MEDIUM, fs, q);
        const Rc tip{std::min(quitR.cx() - tw * 0.5f - S(9.f), (float)cv.w - tw - S(26.f)), quitR.b() + S(6.f),
                     tw + S(18.f), S(26.f)};
        cv.shadow(tip, S(6.f), S(10.f), Bk(0.45f), S(3.f));
        cv.fillRoundRect(tip, S(6.f), RGBA{0.16f, 0.07f, 0.08f, 0.98f});
        cv.strokeRoundRect(tip, S(6.f), px1(), RGBA{1.f, 0.42f, 0.42f, 0.45f});
        vx::text().drawIn(cv, FONT_MEDIUM, fs, tip, q, RGBA{1.f, 0.84f, 0.84f, 1.f}, 1);
    }
    if (iconButton(ID("close"), closeR, IC_CLOSE, "Hide  \xC2\xB7  " + keyName(st.menuKey))) out_->hideMenu = true;
}

void SettingsPanel::paintStage(Canvas& cv, const Rc& r, int bg) {
    const float rad = S(14.f);
    switch (bg) {
        case 1: {  // dusk scene
            const float horizon = r.y + r.h * 0.64f;
            cv.paintRoundRect(r, rad, [&](float, float y, float* o) {
                RGBA c;
                if (y < horizon) {
                    const float t = clamp01((y - r.y) / (horizon - r.y));
                    const RGBA top{0.10f, 0.12f, 0.20f, 1}, mid{0.33f, 0.31f, 0.45f, 1}, low{0.86f, 0.56f, 0.45f, 1};
                    c = t < 0.72f ? mix(top, mid, t / 0.72f) : mix(mid, low, (t - 0.72f) / 0.28f);
                } else {
                    c = mix(RGBA{0.17f, 0.14f, 0.15f, 1}, RGBA{0.06f, 0.055f, 0.06f, 1},
                            smooth((y - horizon) / (r.b() - horizon)));
                }
                o[0] = c.r; o[1] = c.g; o[2] = c.b; o[3] = 1;
            });
            break;
        }
        case 2:  // daylight
            cv.fillRoundRectGrad(r, rad, RGBA{0.90f, 0.91f, 0.92f, 1}, RGBA{0.80f, 0.81f, 0.83f, 1});
            break;
        case 3: {  // reticle grid
            cv.fillRoundRect(r, rad, RGBA{0.045f, 0.045f, 0.05f, 1});
            const float cx = std::round(r.cx()), cy = std::round(r.cy() - S(20.f));
            cv.pushClip(r.inset(S(1.f)));
            for (int i = 1; i <= 4; ++i) cv.strokeCircle(cx, cy, S(55.f) * i, std::max(1.f, S(1.f)), W(i == 2 ? 0.07f : 0.04f));
            cv.fillRect(Rc{cx, r.y, std::max(1.f, S(1.f)), r.h}, W(0.05f));
            cv.fillRect(Rc{r.x, cy, r.w, std::max(1.f, S(1.f))}, W(0.05f));
            cv.popClip();
            break;
        }
        default: {  // studio: near-black with a soft pool of light
            const float cx = r.cx(), cy = r.cy() - S(20.f);
            cv.paintRoundRect(r, rad, [&](float x, float y, float* o) {
                const float dx = (x - cx) / (r.w * 0.62f), dy = (y - cy) / (r.h * 0.62f);
                const float d = std::sqrt(dx * dx + dy * dy);
                const float v = 0.030f + 0.042f * (1.f - smooth(d));
                o[0] = v; o[1] = v; o[2] = v * 1.06f; o[3] = 1.f;
            });
            break;
        }
    }
}

void SettingsPanel::drawStage() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    const Rc r = R(kStageX, kStageY, kStageW, kStageH);
    previewPx_ = r;
    const float rad = S(14.f);
    {
        char k[48];
        std::snprintf(k, sizeof(k), "%d %.3f", st.previewBg, s_);
        cachedImage(stageCache_, "stage", r, k, [&](Canvas& c, const Rc& lr) { paintStage(c, lr, st.previewBg); });
    }
    const bool light = st.previewBg == 2;
    const RGBA quiet = light ? Bk(0.45f) : W(0.40f);
    const float cxs = std::round(r.cx()), cys = std::round(r.cy() - S(20.f));

    // ---- the opening: a faint ring expands while the crosshair assembles
    const float t = since(openTime_);
    float introScale = 1.f, introAlpha = 1.f, introSpin = 0.f;
    if (t < 1.2f) {
        introScale = 0.50f + 0.50f * easeOut5((t - 0.08f) / 0.80f);
        introAlpha = easeOut3((t - 0.08f) / 0.30f);
        introSpin = -1.35f * (1.f - easeOut3((t - 0.08f) / 0.95f));
        cv.pushClip(r.inset(S(1.f)));
        for (int k = 0; k < 2; ++k) {
            const float p = (t - 0.14f - 0.16f * k) / 0.95f;
            if (p <= 0.f || p >= 1.f) continue;
            const float rr = S(14.f + 190.f * easeOut3(p));
            const float a = (k == 0 ? 0.20f : 0.10f) * std::pow(1.f - p, 1.6f);
            cv.strokeCircle(cxs, cys, rr, px1(), light ? Bk(a) : W(a));
        }
        cv.popClip();
    }

    // ---- crosshair: enlarged and crisp (re-rendered at size), or actual pixels (1:1)
    const Rc segR{r.x + S(12.f), r.b() - S(12.f) - S(28.f), S(148.f), S(28.f)};
    const Rc bgR{r.r() - S(12.f) - S(112.f), r.b() - S(12.f) - S(28.f), S(112.f), S(28.f)};
    bool hovStage = false, heldStage = false;
    if (!hovered(segR) && !hovered(bgR)) behave(ID("stage"), r, &hovStage, &heldStage);
    if (hovStage) out_->cursor = CURSOR_ARROW;
    CrosshairStyle cs = effectiveStyle(st, in_.time);
    auto bit = anim_.find(ID("pv-boost"));
    float boost = bit == anim_.end() ? 0.f : bit->second;
    {
        const float target = (heldStage && st.clickReact != REACT_NONE) ? 1.f : 0.f;
        const float k = 1.f - std::exp(-(target > boost ? 10.f : 4.f) * std::min(in_.dt, 0.1f));
        boost += (target - boost) * k;
        if (std::fabs(target - boost) < 0.002f) boost = target;
        anim_[ID("pv-boost")] = boost;
    }
    const bool actual = st.previewZoom == 1;
    const float outerR = std::max(1.f, (cs.gap + cs.length) * std::max(0.05f, cs.scale));
    const float k = actual ? 1.f : std::max(1.f, std::min(8.f, S(118.f) / outerR));
    cs.scale *= k;
    cs.opacity *= introAlpha * cv.globalAlpha;
    stageRenderer_.prepare(cs);
    float speed = st.spin ? st.spinSpeed : 0.f;
    if (st.clickReact == REACT_SPIN) speed += (speed > 0 ? speed : 180.f) * 2.f * boost;
    previewAngle_ += (st.spinDir == 0 ? 1.f : -1.f) * speed * (kPi / 180.f) * std::min(in_.dt, 0.1f);
    previewAngle_ = std::fmod(previewAngle_, 2.f * kPi);
    const float pulse = st.clickReact == REACT_PULSE ? 1.f + 0.18f * boost : 1.f;
    cv.pushClip(r.inset(S(1.f)));
    stageRenderer_.render(cv.px, cv.w, cv.h, cv.stride, cxs, cys,
                          previewAngle_ + introSpin * (st.spinDir == 0 ? 1.f : -1.f), cs, cv.clipX0, cv.clipY0,
                          cv.clipX1, cv.clipY1, introScale * pulse);
    cv.popClip();
    if (speed > 0.f || st.rainbow || boost > 0.f) previewAnimating_ = true;

    // ---- quiet labels and controls on the stage
    text(kStageX + 18.f, kStageY + 28.f, "Preview", 12.f, FONT_MEDIUM, quiet);
    if (st.spin && st.spinSpeed > 0.f) {
        const std::string sp = fmtInt(st.spinSpeed, "\xC2\xB0/s");
        vx::text().drawIn(cv, FONT_MEDIUM, S(12.f), R(kStageX + kStageW - 18.f - 100.f, kStageY + 14.f, 100.f, 20.f), sp,
                          quiet, 2);
    }
    {
        int mode = actual ? 1 : 0;
        if (light) cv.fillRoundRect(segR, S(8.f), RGBA{0.10f, 0.10f, 0.11f, 0.88f});  // keep it legible on daylight
        if (segmented(ID("stage-zoom"), segR, {"Enlarged", "1:1"}, mode)) st.previewZoom = mode == 1 ? 1 : 2;
        tooltip(ID("stage-zoom") + 2, Rc{segR.x + segR.w * 0.5f, segR.y, segR.w * 0.5f, segR.h}, "Actual pixel size");
    }
    {
        const RGBA chip[4] = {RGBA{0.08f, 0.08f, 0.09f, 1}, RGBA{0.55f, 0.43f, 0.50f, 1}, RGBA{0.88f, 0.89f, 0.90f, 1},
                              RGBA{0.16f, 0.16f, 0.18f, 1}};
        const char* names[4] = {"Studio", "Dusk", "Daylight", "Reticle"};
        for (int i = 0; i < 4; ++i) {
            const float cx = bgR.x + S(14.f) + i * S(28.f), cy = bgR.cy();
            const Rc hit{cx - S(13.f), bgR.y, S(26.f), bgR.h};
            bool hv = false;
            if (behave(ID("stage-bg", i), hit, &hv) && st.previewBg != i) {
                st.previewBg = i;
                changed();
            }
            tooltip(ID("stage-bg", i), hit, names[i]);
            const float sel = anim(ID("stage-bgsel", i), st.previewBg == i ? 1.f : 0.f, 20.f);
            if (sel > 0.01f) cv.strokeCircle(cx, cy, S(9.f), S(1.5f), alpha(light ? Bk(0.75f) : W(0.85f), sel));
            cv.fillCircle(cx, cy, S(6.f), chip[i]);
            cv.strokeCircle(cx, cy, S(6.f), px1(), light ? Bk(0.25f) : W(hv ? 0.45f : 0.22f));
        }
    }
    cv.strokeRoundRect(r, rad, px1(), light ? Bk(0.12f) : W(0.075f));
}

void SettingsPanel::drawTabs() {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    float x = kInsX;
    float selX = 0.f, selW = 0.f;
    const float fs = 13.f;
    for (int i = 0; i < 5; ++i) {
        const float tw = vx::text().measure(FONT_MEDIUM, S(fs), kTabs[i]) / s_;
        const Rc hit = R(x - 8.f, kTabsY + 6.f, tw + 16.f, 34.f);
        bool hov = false;
        if (behave(ID("tab", i), hit, &hov) && st.page != i) {
            st.page = i;
            changed();
        }
        const float hv = anim(ID("tabh", i), hov ? 1.f : 0.f, 20.f);
        const bool on = st.page == i;
        text(x, kTabsY + 28.f, kTabs[i], fs, FONT_MEDIUM, W(on ? 0.95f : 0.46f + 0.26f * hv));
        if (on) {
            selX = x;
            selW = tw;
        }
        x += tw + 26.f;
    }
    // hairline + sliding indicator
    separator(kInsX, kTabsY + 42.f, kInsW);
    const float ix = spring(ID("tab-ind-x"), selX, 420.f, 41.f);
    const float iw = spring(ID("tab-ind-w"), selW, 420.f, 41.f);
    cv.fillRoundRect(R(ix, kTabsY + 41.f, iw, 2.f), S(1.f), W(0.92f));
}

void SettingsPanel::drawFooter() {
    Settings& st = *st_;
    const float y = kHeight - 16.f - 30.f;
    separator(kInsX, y - 12.f, kInsW);
    const std::string kn = keyName(st.menuKey);
    const float kw = vx::text().measure(FONT_MEDIUM, S(11.f), kn) / s_ + 16.f;
    keycap(R(kInsX, y + 5.f, kw, 20.f), kn, false, true);
    text(kInsX + kw + 9.f, y + 19.f, "shows and hides this menu", 12.f, FONT_REGULAR, W(0.40f));
    if (ghostButton(ID("reset"), R(kInsX + kInsW - 148.f, y, 148.f, 30.f), "Reset to original", IC_RESET)) {
        resetLook(st);
        changed();
        pickLast_ = RGBA{-1, -1, -1, -1};
    }
}

// ============================================================ pages

void SettingsPanel::pageStyle(float x, float y, float w) {
    Canvas& cv = *cv_;
    Settings& st = *st_;
    // presets
    float o = beginRow();
    sectionTitle(x, y + 12.f + o, "Presets");
    endRow();
    o = beginRow();
    {
        const int cur = matchPreset(st);
        const int n = std::min(8, presetCount());
        const float d = 44.f;
        const float gap = (w - n * d) / (n - 1);
        CrosshairStyle base = st.style;
        base.scale = 0.50f * s_ * std::min(1.3f, std::max(0.7f, st.style.scale));
        base.shadow = 0.f;
        base.opacity = cv.globalAlpha;
        chipRenderer_.prepare(base);
        for (int i = 0; i < n; ++i) {
            const Rc r = R(x + i * (d + gap), y + 26.f + o, d, d);
            bool hov = false;
            if (behave(ID("preset", i), r, &hov)) {
                applyPreset(st, i);
                st.rainbow = false;
                changed();
            }
            const ColorPreset& p = preset(i);
            tooltip(ID("preset", i), r, p.name);
            const float hv = anim(ID("preseth", i), hov ? 1.f : 0.f, 18.f);
            const float sel = anim(ID("presets", i), cur == i ? 1.f : 0.f, 18.f);
            cv.fillCircle(r.cx(), r.cy(), r.w * 0.5f,
                          RGBA{0.085f + 0.03f * hv, 0.085f + 0.03f * hv, 0.095f + 0.03f * hv, 1.f});
            cv.strokeCircle(r.cx(), r.cy(), r.w * 0.5f - px1() * 0.5f, px1(), W(0.09f + 0.10f * hv));
            if (sel > 0.01f) cv.strokeCircle(r.cx(), r.cy(), r.w * 0.5f + S(3.5f), S(1.5f), W(0.90f * sel));
            CrosshairStyle cs = base;
            cs.fill = p.fill;
            cs.line = p.line;
            cs.dotCol = p.dot;
            cs.glowCol = p.glow;
            if (hov) {
                chipAngle_[i] += in_.dt * 2.6f;
                animating_ = true;
            }
            cv.pushClip(r.inset(S(2.f)));
            chipRenderer_.render(cv.px, cv.w, cv.h, cv.stride, std::round(r.cx()), std::round(r.cy()),
                                 -0.3175f + chipAngle_[i], cs, cv.clipX0, cv.clipY0, cv.clipX1, cv.clipY1);
            cv.popClip();
        }
    }
    endRow();

    // colour
    o = beginRow();
    sectionTitle(x, y + 104.f + o, "Color");
    segmented(ID("ctarget"), R(x + w - 272.f, y + 86.f + o, 272.f, 28.f), {"Fill", "Outline", "Dot", "Glow"},
              st.colorTarget);
    endRow();
    RGBA* cols[4] = {&st.style.fill, &st.style.line, &st.style.dotCol, &st.style.glowCol};
    RGBA& c = *cols[std::max(0, std::min(3, st.colorTarget))];
    colorPicker(x, y + 126.f, w, c);

    // rainbow
    o = beginRow();
    const float ry = y + 394.f + o;
    separator(x, ry, w);
    text(x, ry + 30.f, "Rainbow cycle", 13.f, FONT_MEDIUM, W(0.86f));
    if (st.rainbow) {
        int sp = st.rainbowSpeed < 0.12f ? 0 : (st.rainbowSpeed < 0.35f ? 1 : 2);
        const int before = sp;
        segmented(ID("rbspeed"), R(x + w - 38.f - 16.f - 186.f, ry + 11.f, 186.f, 28.f), {"Slow", "Medium", "Fast"}, sp);
        if (sp != before) st.rainbowSpeed = sp == 0 ? 0.08f : (sp == 1 ? 0.2f : 0.55f);
    }
    toggle(ID("rainbow"), R(x + w - 38.f, ry + 14.f, 38.f, 22.f), st.rainbow);
    endRow();
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
    auto ring = [&](float kx, float ky, float kr, const RGBA& inner) {
        cv.shadow(Rc{kx - kr, ky - kr, kr * 2, kr * 2}, kr, S(5.f), Bk(0.45f), S(1.f));
        cv.fillCircle(kx, ky, kr, W(1.f));
        cv.fillCircle(kx, ky, kr - S(2.5f), RGBA{inner.r, inner.g, inner.b, 1.f});
    };

    // saturation / value field
    float o = beginRow();
    const Rc sv = R(x, y + o, w, 120.f);
    bool heldSV = false;
    behave(ID("sv"), sv, nullptr, &heldSV);
    if (heldSV) {
        pickS_ = clamp01((in_.mx - sv.x) / sv.w);
        pickV_ = 1.f - clamp01((in_.my - sv.y) / sv.h);
        modified = true;
    }
    {
        const float H = pickH_;
        char k[32];
        std::snprintf(k, sizeof(k), "%.4f %.3f", H, s_);
        cachedImage(svCache_, "sv", sv, k, [&](Canvas& c, const Rc& lr) {
            c.paintRoundRect(lr, S(10.f), [&](float px, float py, float* out) {
                const RGBA col = hsvToRgb(H, clamp01((px - lr.x) / lr.w), 1.f - clamp01((py - lr.y) / lr.h));
                out[0] = col.r; out[1] = col.g; out[2] = col.b; out[3] = 1.f;
            });
            c.strokeRoundRect(lr, S(10.f), std::max(1.f, S(1.f)), W(0.10f));
        });
    }
    ring(sv.x + pickS_ * sv.w, sv.y + (1.f - pickV_) * sv.h, S(heldSV ? 9.f : 8.f), hsvToRgb(pickH_, pickS_, pickV_));
    endRow();

    // hue
    o = beginRow();
    const Rc hue = R(x, y + 136.f + o, w, 10.f);
    bool heldH = false;
    behave(ID("hue"), hue.inset(0, -S(7.f)), nullptr, &heldH);
    if (heldH) {
        pickH_ = clamp01((in_.mx - hue.x) / hue.w) * 0.9999f;
        modified = true;
    }
    cachedImage(hueCache_, "hue", hue, std::to_string(s_), [&](Canvas& c, const Rc& lr) {
        c.paintRoundRect(lr, lr.h * 0.5f, [&](float px, float, float* out) {
            const RGBA col = hsvToRgb(clamp01((px - lr.x) / lr.w) * 0.9999f, 1.f, 1.f);
            out[0] = col.r; out[1] = col.g; out[2] = col.b; out[3] = 1.f;
        });
    });
    ring(hue.x + pickH_ * hue.w, hue.cy(), S(heldH ? 9.f : 8.f), hsvToRgb(pickH_, 1.f, 1.f));
    endRow();

    // opacity
    o = beginRow();
    const Rc al = R(x, y + 160.f + o, w, 10.f);
    bool heldA = false;
    behave(ID("alpha"), al.inset(0, -S(7.f)), nullptr, &heldA);
    if (heldA) {
        color.a = std::round(clamp01((in_.mx - al.x) / al.w) * 100.f) / 100.f;
        changed();
    }
    const RGBA base = hsvToRgb(pickH_, pickS_, pickV_);
    {
        char k[64];
        std::snprintf(k, sizeof(k), "%.4f %.4f %.4f %.3f", base.r, base.g, base.b, s_);
        const float cell = S(5.f);
        cachedImage(alphaCache_, "alpha", al, k, [&](Canvas& c, const Rc& lr) {
            c.paintRoundRect(lr, lr.h * 0.5f, [&](float px, float py, float* out) {
                const int cx = (int)std::floor((px - lr.x) / cell), cy = (int)std::floor((py - lr.y) / cell);
                const float chk = ((cx + cy) & 1) ? 0.40f : 0.25f;
                const float t = clamp01((px - lr.x) / lr.w);
                out[0] = chk + (base.r - chk) * t;
                out[1] = chk + (base.g - chk) * t;
                out[2] = chk + (base.b - chk) * t;
                out[3] = 1.f;
            });
        });
    }
    ring(al.x + color.a * al.w, al.cy(), S(heldA ? 9.f : 8.f), base);
    endRow();

    if (modified) {
        const float a = color.a;
        color = hsvToRgb(pickH_, pickS_, pickV_, a);
        changed();
    }

    // value row: swatch, hex, opacity, copy
    o = beginRow();
    const float ry = y + 186.f + o;
    const Rc sw = R(x, ry, 32.f, 32.f);
    cv.fillRoundRect(sw, S(8.f), RGBA{color.r, color.g, color.b, 1.f});
    cv.strokeRoundRect(sw, S(8.f), px1(), W(0.12f));
    hexField(ID("hex"), R(x + 40.f, ry, w - 40.f - 8.f - 64.f - 8.f - 32.f, 32.f), color);
    {
        const Rc ar = R(x + w - 32.f - 8.f - 64.f, ry, 64.f, 32.f);
        cv.fillRoundRect(ar, S(8.f), W(0.045f));
        cv.strokeRoundRect(ar, S(8.f), px1(), W(0.08f));
        vx::text().drawIn(cv, FONT_MEDIUM, S(12.5f), ar, fmtInt(color.a * 100.f, "%"), W(0.80f), 1);
    }
    if (iconButton(ID("copyhex"), R(x + w - 32.f, ry, 32.f, 32.f), IC_COPY, "Copy hex"))
        out_->copyText = toHex(color, color.a < 0.999f);
    endRow();

    // swatches
    o = beginRow();
    const float sy = y + 234.f + o;
    const int n = 12;
    const float d = 20.f;
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
        const float hv = anim(ID("swh", i), hov ? 1.f : 0.f, 22.f);
        const float rr = S(d * 0.5f) * (1.f + 0.08f * hv);
        if (same) cv.strokeCircle(r.cx(), r.cy(), rr + S(3.f), S(1.5f), W(0.85f));
        cv.fillCircle(r.cx(), r.cy(), rr, c);
        cv.strokeCircle(r.cx(), r.cy(), rr - px1() * 0.5f, px1(), Bk(0.25f));
    }
    endRow();
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
        auto clearAll = [&]() {
            hexEdit_.clear();
            caret_ = 0;
            hexSelectAll_ = false;
        };
        if (in_.kPaste && !in_.clipboard.empty()) {
            std::string p;
            for (char ch : in_.clipboard)
                if (std::isxdigit((unsigned char)ch)) p += (char)std::toupper((unsigned char)ch);
            if (hexSelectAll_) clearAll();
            hexEdit_.insert(caret_, p.substr(0, 8 - std::min<size_t>(8, hexEdit_.size())));
            caret_ = std::min(hexEdit_.size(), caret_ + p.size());
            edited = true;
        }
        for (char ch : in_.typed) {
            if (!std::isxdigit((unsigned char)ch)) continue;
            if (hexSelectAll_) clearAll();
            if (hexEdit_.size() >= 8) continue;
            hexEdit_.insert(hexEdit_.begin() + (long)caret_, (char)std::toupper((unsigned char)ch));
            ++caret_;
            edited = true;
        }
        if (in_.kSelectAll) hexSelectAll_ = true;
        if (in_.kBack) {
            if (hexSelectAll_) {
                clearAll();
            } else if (caret_ > 0) {
                hexEdit_.erase(caret_ - 1, 1);
                --caret_;
            }
            edited = true;
        }
        if (in_.kDelete) {
            if (hexSelectAll_)
                clearAll();
            else if (caret_ < hexEdit_.size())
                hexEdit_.erase(caret_, 1);
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
    const float fa = anim(id ^ 0x3u, focused ? 1.f : 0.f, 20.f);
    const float rad = S(8.f);
    cv.fillRoundRect(r, rad, W(0.045f + 0.02f * fa));
    cv.strokeRoundRect(r, rad, px1(), W(0.08f + 0.04f * (hov ? 1.f : 0.f) + 0.30f * fa));
    const std::string shown = focused ? hexEdit_ : toHex(color, false).substr(1);
    const float fs = S(12.5f);
    const float tx = r.x + S(12.f);
    const float baseline = r.cy() + vx::text().capHeight(FONT_MEDIUM, fs) * 0.5f;
    const float hashW = vx::text().draw(cv, FONT_MEDIUM, fs, tx, baseline, "#", W(0.35f));
    const float vx0 = tx + hashW + S(2.f);
    if (focused && hexSelectAll_ && !hexEdit_.empty()) {
        const float swd = vx::text().measure(FONT_MEDIUM, fs, hexEdit_, S(0.5f));
        cv.fillRoundRect(Rc{vx0 - S(2.f), r.cy() - S(9.f), swd + S(4.f), S(18.f)}, S(3.f), W(0.22f));
    }
    vx::text().draw(cv, FONT_MEDIUM, fs, vx0, baseline, shown, W(0.90f), S(0.5f));
    if (focused) {
        const float blink = std::fmod((float)(in_.time - caretTime_), 1.06f) < 0.53f ? 1.f : 0.f;
        if (blink > 0.f) {
            const float cx = vx0 + vx::text().measure(FONT_MEDIUM, fs, hexEdit_.substr(0, caret_), S(0.5f)) +
                             (caret_ > 0 ? S(0.5f) : 0.f);
            cv.fillRect(Rc{std::round(cx), r.cy() - S(7.f), std::max(1.f, S(1.25f)), S(14.f)}, W(0.9f));
        }
    }
}

void SettingsPanel::pageShape(float x, float y, float w) {
    Settings& st = *st_;
    CrosshairStyle& c = st.style;
    float o = beginRow();
    group(x, y + o, w, kRowH * 7.f);
    endRow();
    float yy = y;
    o = beginRow();
    sliderRow(ID("scale"), x, yy + o, w, "Size", fmtInt(c.scale * 100.f, "%"), c.scale, 0.5f, 4.f, 0.05f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("length"), x, yy + o, w, "Blade length", fmt1(c.length, " px"), c.length, 6.f, 60.f, 0.1f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("width"), x, yy + o, w, "Blade width", fmt1(c.width, " px"), c.width, 2.f, 24.f, 0.1f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("gap"), x, yy + o, w, "Center gap", fmt1(c.gap, " px"), c.gap, 0.f, 30.f, 0.1f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    {
        text(x + 16.f, yy + o + kRowH * 0.5f + 4.5f, "Outline", 13.f, FONT_MEDIUM, W(0.86f));
        toggle(ID("outline-on"), R(x + 84.f, yy + o + kRowH * 0.5f - 9.f, 32.f, 18.f), c.showOutline);
        vx::text().drawIn(*cv_, FONT_MEDIUM, S(12.5f), R(x + w - 16.f - 56.f, yy + o, 56.f, kRowH),
                          c.showOutline ? fmt1(c.outline, " px") : std::string("Off"), W(0.50f), 2);
        const float ga = cv_->globalAlpha;
        if (!c.showOutline) cv_->globalAlpha = ga * 0.35f;
        slider(ID("outline"), R(x + 148.f, yy + o + kRowH * 0.5f - 11.f, w - 148.f - 16.f - 68.f, 22.f), c.outline, 0.f,
               4.f, 0.05f);
        cv_->globalAlpha = ga;
    }
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("dot"), x, yy + o, w, "Center dot", c.dot > 0.01f ? fmt1(c.dot, " px") : std::string("Off"), c.dot, 0.f,
              6.f, 0.05f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    {
        static const int counts[6] = {2, 3, 4, 5, 6, 8};
        int sel = 2;
        for (int i = 0; i < 6; ++i)
            if (counts[i] == c.blades) sel = i;
        const int before = sel;
        segmentRow(ID("blades"), x, yy + o, w, "Blades", {"2", "3", "4", "5", "6", "8"}, sel, 248.f);
        if (sel != before) c.blades = counts[sel];
    }
    endRow();
}

void SettingsPanel::pageMotion(float x, float y, float w) {
    Settings& st = *st_;
    float o = beginRow();
    group(x, y + o, w, kRowH * 4.f);
    endRow();
    float yy = y;
    o = beginRow();
    toggleRow(ID("spin"), x, yy + o, w, "Spin", st.spin);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    if (!st.spin) cv_->globalAlpha *= 0.4f;
    sliderRow(ID("speed"), x, yy + o, w, "Speed", fmtInt(st.spinSpeed, "\xC2\xB0/s"), st.spinSpeed, 0.f, 1080.f, 5.f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    if (!st.spin) cv_->globalAlpha *= 0.4f;
    {
        static const float speeds[4] = {60.f, 150.f, 360.f, 720.f};
        int sel = -1;
        for (int i = 0; i < 4; ++i)
            if (std::fabs(st.spinSpeed - speeds[i]) < 0.5f) sel = i;
        const int before = sel;
        segmentRow(ID("spdpreset"), x, yy + o, w, "Quick set", {"Chill", "Smooth", "Fast", "Turbo"}, sel, 248.f);
        if (sel != before && sel >= 0) {
            st.spinSpeed = speeds[sel];
            st.spin = true;
        }
    }
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    if (!st.spin) cv_->globalAlpha *= 0.4f;
    segmentRow(ID("dir"), x, yy + o, w, "Direction", {"Clockwise", "Counter"}, st.spinDir, 248.f);
    endRow();

    yy = y + kRowH * 4.f + 16.f;
    o = beginRow();
    group(x, yy + o, w, kRowH);
    segmentRow(ID("react"), x, yy + o, w, "Click reaction", {"None", "Spin boost", "Pulse"}, st.clickReact, 248.f);
    endRow();
    o = beginRow();
    text(x + 16.f, yy + kRowH + 22.f + o, "Reacts while you hold the left mouse button. Try it on the preview.", 12.f,
         FONT_REGULAR, W(0.38f));
    endRow();
}

void SettingsPanel::pageEffects(float x, float y, float w) {
    Settings& st = *st_;
    CrosshairStyle& c = st.style;
    float g = c.glow * 100.f, gs = c.glowSize * 100.f, h = c.halo * 100.f, sh = c.shadow * 100.f,
          op = c.opacity * 100.f;
    float o = beginRow();
    group(x, y + o, w, kRowH * 5.f);
    endRow();
    float yy = y;
    o = beginRow();
    sliderRow(ID("glow"), x, yy + o, w, "Glow", fmtInt(g, "%"), g, 0.f, 250.f, 1.f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("glowsize"), x, yy + o, w, "Glow spread", fmtInt(gs, "%"), gs, 50.f, 300.f, 1.f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("halo"), x, yy + o, w, "Dot halo", fmtInt(h, "%"), h, 0.f, 300.f, 1.f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("shadow"), x, yy + o, w, "Contrast shadow", sh < 0.5f ? std::string("Off") : fmtInt(sh, "%"), sh, 0.f,
              100.f, 1.f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("opacity"), x, yy + o, w, "Opacity", fmtInt(op, "%"), op, 10.f, 100.f, 1.f);
    endRow();
    c.glow = g / 100.f;
    c.glowSize = gs / 100.f;
    c.halo = h / 100.f;
    c.shadow = sh / 100.f;
    c.opacity = op / 100.f;
    o = beginRow();
    text(x + 16.f, y + kRowH * 5.f + 22.f + o, "Contrast shadow keeps the outline readable on bright scenes.", 12.f,
         FONT_REGULAR, W(0.38f));
    endRow();
}

void SettingsPanel::pageGeneral(float x, float y, float w) {
    Settings& st = *st_;
    float o = beginRow();
    group(x, y + o, w, kRowH * 3.f);
    endRow();
    float yy = y;
    o = beginRow();
    segmentRow(ID("pos"), x, yy + o, w, "Position", {"Follow cursor", "Screen center"}, st.position, 248.f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    float ox = (float)st.offsetX, oy = (float)st.offsetY;
    o = beginRow();
    sliderRow(ID("offx"), x, yy + o, w, "Nudge X", fmtInt(ox, " px"), ox, -50.f, 50.f, 1.f);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    sliderRow(ID("offy"), x, yy + o, w, "Nudge Y", fmtInt(oy, " px"), oy, -50.f, 50.f, 1.f);
    endRow();
    st.offsetX = (int)std::lround(ox);
    st.offsetY = (int)std::lround(oy);

    yy = y + kRowH * 3.f + 16.f;
    o = beginRow();
    group(x, yy + o, w, kRowH * 3.f);
    endRow();
    o = beginRow();
    toggleRow(ID("hidecur"), x, yy + o, w, "Hide Windows cursor", st.hideCursor);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    toggleRow(ID("hidecap"), x, yy + o, w, "Hide from screen capture", st.hideFromCapture);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    yy += kRowH;
    o = beginRow();
    toggleRow(ID("autostart"), x, yy + o, w, "Start with Windows", st.startWithWindows);
    endRow();

    yy = y + kRowH * 6.f + 32.f;
    o = beginRow();
    group(x, yy + o, w, kRowH * 2.f);
    endRow();
    auto bindRow = [&](int which, float ry, const char* name, int vk) {
        text(x + 16.f, ry + kRowH * 0.5f + 4.5f, name, 13.f, FONT_MEDIUM, W(0.86f));
        const bool cap = status_->capturing == which;
        const std::string kn = cap ? std::string("Press a key\xE2\x80\xA6") : keyName(vk);
        const float kw = std::max(S(84.f), vx::text().measure(FONT_MEDIUM, S(12.f), kn) + S(24.f));
        const Rc key{S(x + w - 16.f) - kw, S(ry + kRowH * 0.5f - 13.f), kw, S(26.f)};
        bool hov = false;
        if (behave(ID("bind", which), key, &hov)) {
            if (cap)
                out_->cancelBind = true;
            else
                out_->bindKey = which;
        }
        if (hov) bindHovered_ = true;
        if (cap) animating_ = true;
        keycap(key, kn, cap);
        if (which == 2 && vk != 0 && !cap) {
            const Rc clr{key.x - S(34.f), key.y - S(3.f), S(32.f), S(32.f)};
            if (iconButton(ID("bindclr"), clr, IC_CLOSE, "Clear")) out_->clearToggleKey = true;
        }
    };
    o = beginRow();
    bindRow(1, yy + o, "Menu key", st.menuKey);
    endRow();
    separator(x + 16.f, yy + kRowH, w - 16.f);
    o = beginRow();
    bindRow(2, yy + kRowH + o, "Show / hide crosshair", st.toggleKey);
    endRow();
}

}  // namespace vx
