// Vortex Crosshair - settings, presets, persistence
#include "settings.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace vx {

namespace {
const ColorPreset kPresets[] = {
    {"Original", rgb8(255, 200, 210), rgb8(255, 255, 255), rgb8(255, 255, 255), rgb8(255, 255, 255)},
    {"Sakura", rgb8(255, 140, 186), rgb8(255, 232, 241), rgb8(255, 255, 255), rgb8(255, 110, 168)},
    {"Glacier", rgb8(150, 228, 255), rgb8(255, 255, 255), rgb8(255, 255, 255), rgb8(110, 210, 255)},
    {"Toxic", rgb8(184, 255, 92), rgb8(246, 255, 232), rgb8(255, 255, 255), rgb8(140, 255, 60)},
    {"Inferno", rgb8(255, 112, 64), rgb8(255, 230, 216), rgb8(255, 255, 255), rgb8(255, 70, 40)},
    {"Royal", rgb8(184, 156, 255), rgb8(255, 255, 255), rgb8(255, 255, 255), rgb8(150, 118, 255)},
    {"Gold", rgb8(255, 210, 110), rgb8(255, 247, 222), rgb8(255, 255, 255), rgb8(255, 190, 60)},
    {"Ghost", rgb8(255, 255, 255), rgb8(255, 255, 255), rgb8(255, 255, 255), rgb8(255, 255, 255)},
};

bool near(const RGBA& a, const RGBA& b) {
    return std::fabs(a.r - b.r) < 0.004f && std::fabs(a.g - b.g) < 0.004f && std::fabs(a.b - b.b) < 0.004f &&
           std::fabs(a.a - b.a) < 0.004f;
}

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n')) --b;
    return s.substr(a, b - a);
}

float clampf(float v, float lo, float hi) { return std::isfinite(v) ? std::max(lo, std::min(hi, v)) : lo; }
int clampi(int v, int lo, int hi) { return std::max(lo, std::min(hi, v)); }

std::string fmt(float v) {
    char b[32];
    std::snprintf(b, sizeof(b), "%.4g", v);
    return b;
}
}  // namespace

int presetCount() { return (int)(sizeof(kPresets) / sizeof(kPresets[0])); }
const ColorPreset& preset(int i) { return kPresets[std::max(0, std::min(presetCount() - 1, i))]; }

void applyPreset(Settings& s, int i) {
    const ColorPreset& p = preset(i);
    s.style.fill = p.fill;
    s.style.line = p.line;
    s.style.dotCol = p.dot;
    s.style.glowCol = p.glow;
}

int matchPreset(const Settings& s) {
    for (int i = 0; i < presetCount(); ++i) {
        const ColorPreset& p = kPresets[i];
        if (near(s.style.fill, p.fill) && near(s.style.line, p.line) && near(s.style.dotCol, p.dot) &&
            near(s.style.glowCol, p.glow))
            return i;
    }
    return -1;
}

void resetLook(Settings& s) {
    s.style = CrosshairStyle();
    s.rainbow = false;
}

// ------------------------------------------------------------------ colours
std::string toHex(const RGBA& c, bool withAlpha) {
    auto b = [](float v) { return (int)std::lround(std::max(0.f, std::min(1.f, v)) * 255.f); };
    char buf[16];
    if (withAlpha)
        std::snprintf(buf, sizeof(buf), "#%02X%02X%02X%02X", b(c.r), b(c.g), b(c.b), b(c.a));
    else
        std::snprintf(buf, sizeof(buf), "#%02X%02X%02X", b(c.r), b(c.g), b(c.b));
    return buf;
}

bool parseHex(const std::string& in, RGBA& out) {
    std::string s = trim(in);
    if (!s.empty() && s[0] == '#') s = s.substr(1);
    for (char ch : s)
        if (!std::isxdigit((unsigned char)ch)) return false;
    auto hv = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return c - 'A' + 10;
    };
    int r, g, b, a = 255;
    if (s.size() == 3) {
        r = hv(s[0]) * 17; g = hv(s[1]) * 17; b = hv(s[2]) * 17;
    } else if (s.size() == 6 || s.size() == 8) {
        r = hv(s[0]) * 16 + hv(s[1]);
        g = hv(s[2]) * 16 + hv(s[3]);
        b = hv(s[4]) * 16 + hv(s[5]);
        if (s.size() == 8) a = hv(s[6]) * 16 + hv(s[7]);
    } else {
        return false;
    }
    out = RGBA{r / 255.f, g / 255.f, b / 255.f, a / 255.f};
    return true;
}

void rgbToHsv(const RGBA& c, float& h, float& s, float& v) {
    const float mx = std::max({c.r, c.g, c.b}), mn = std::min({c.r, c.g, c.b});
    const float d = mx - mn;
    v = mx;
    s = mx > 0 ? d / mx : 0;
    if (d <= 1e-6f) {
        h = 0;
        return;
    }
    if (mx == c.r)
        h = std::fmod((c.g - c.b) / d, 6.f);
    else if (mx == c.g)
        h = (c.b - c.r) / d + 2.f;
    else
        h = (c.r - c.g) / d + 4.f;
    h /= 6.f;
    if (h < 0) h += 1.f;
}

RGBA hsvToRgb(float h, float s, float v, float a) {
    h = h - std::floor(h);
    const float hh = h * 6.f;
    const int i = (int)hh % 6;
    const float f = hh - std::floor(hh);
    const float p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
    switch (i) {
        case 0: return RGBA{v, t, p, a};
        case 1: return RGBA{q, v, p, a};
        case 2: return RGBA{p, v, t, a};
        case 3: return RGBA{p, q, v, a};
        case 4: return RGBA{t, p, v, a};
        default: return RGBA{v, p, q, a};
    }
}

CrosshairStyle effectiveStyle(const Settings& s, double t) {
    CrosshairStyle c = s.style;
    if (!s.rainbow) return c;
    const float shift = (float)std::fmod(t * s.rainbowSpeed, 1.0);
    auto cycle = [&](RGBA& col, float extraSat) {
        float h, sat, v;
        rgbToHsv(col, h, sat, v);
        // greys get a gentle tint so "rainbow" is visible on the white parts too
        sat = std::max(sat, extraSat);
        col = hsvToRgb(h + shift, sat, v, col.a);
    };
    cycle(c.fill, 0.45f);
    cycle(c.glowCol, 0.55f);
    cycle(c.line, 0.0f);
    cycle(c.dotCol, 0.0f);
    return c;
}

// ------------------------------------------------------------------ keys
std::string keyName(int vk) {
    if (vk == 0) return "None";
    if ((vk >= '0' && vk <= '9') || (vk >= 'A' && vk <= 'Z')) return std::string(1, (char)vk);
    if (vk >= 0x70 && vk <= 0x87) return "F" + std::to_string(vk - 0x70 + 1);
    if (vk >= 0x60 && vk <= 0x69) return "Num " + std::to_string(vk - 0x60);
    switch (vk) {
        case 0x01: return "Mouse 1";
        case 0x02: return "Mouse 2";
        case 0x04: return "Mouse 3";
        case 0x05: return "Mouse 4";
        case 0x06: return "Mouse 5";
        case 0x08: return "Backspace";
        case 0x09: return "Tab";
        case 0x0D: return "Enter";
        case 0x10: return "Shift";
        case 0x11: return "Ctrl";
        case 0x12: return "Alt";
        case 0x13: return "Pause";
        case 0x14: return "Caps Lock";
        case 0x1B: return "Esc";
        case 0x20: return "Space";
        case 0x21: return "Page Up";
        case 0x22: return "Page Down";
        case 0x23: return "End";
        case 0x24: return "Home";
        case 0x25: return "Left";
        case 0x26: return "Up";
        case 0x27: return "Right";
        case 0x28: return "Down";
        case 0x2C: return "Print Screen";
        case 0x2D: return "Insert";
        case 0x2E: return "Delete";
        case 0x5B: return "Left Win";
        case 0x5C: return "Right Win";
        case 0x5D: return "Menu";
        case 0x6A: return "Num *";
        case 0x6B: return "Num +";
        case 0x6D: return "Num -";
        case 0x6E: return "Num .";
        case 0x6F: return "Num /";
        case 0x90: return "Num Lock";
        case 0x91: return "Scroll Lock";
        case 0xA0: return "Left Shift";
        case 0xA1: return "Right Shift";
        case 0xA2: return "Left Ctrl";
        case 0xA3: return "Right Ctrl";
        case 0xA4: return "Left Alt";
        case 0xA5: return "Right Alt";
        case 0xBA: return ";";
        case 0xBB: return "=";
        case 0xBC: return ",";
        case 0xBD: return "-";
        case 0xBE: return ".";
        case 0xBF: return "/";
        case 0xC0: return "`";
        case 0xDB: return "[";
        case 0xDC: return "\\";
        case 0xDD: return "]";
        case 0xDE: return "'";
        default: {
            char b[24];
            std::snprintf(b, sizeof(b), "Key 0x%02X", vk & 0xFF);
            return b;
        }
    }
}

// ------------------------------------------------------------------ persistence
std::string serializeSettings(const Settings& s) {
    std::string o;
    o.reserve(1024);
    const CrosshairStyle& c = s.style;
    auto kv = [&](const char* k, const std::string& v) {
        o += k;
        o += '=';
        o += v;
        o += '\n';
    };
    auto ki = [&](const char* k, int v) { kv(k, std::to_string(v)); };
    auto kf = [&](const char* k, float v) { kv(k, fmt(v)); };
    o += "; Vortex Crosshair settings (safe to delete to restore defaults)\n[crosshair]\n";
    ki("blades", c.blades);
    kf("length", c.length);
    kf("width", c.width);
    kf("gap", c.gap);
    kf("outline", c.outline);
    ki("showOutline", c.showOutline ? 1 : 0);
    kf("dot", c.dot);
    kf("scale", c.scale);
    kf("glow", c.glow);
    kf("glowSize", c.glowSize);
    kf("halo", c.halo);
    kf("shadow", c.shadow);
    kf("opacity", c.opacity);
    kv("fill", toHex(c.fill, true));
    kv("line", toHex(c.line, true));
    kv("dotColor", toHex(c.dotCol, true));
    kv("glowColor", toHex(c.glowCol, true));
    o += "[behaviour]\n";
    ki("enabled", s.enabled ? 1 : 0);
    ki("spin", s.spin ? 1 : 0);
    kf("spinSpeed", s.spinSpeed);
    ki("spinDir", s.spinDir);
    ki("clickReact", s.clickReact);
    ki("rainbow", s.rainbow ? 1 : 0);
    kf("rainbowSpeed", s.rainbowSpeed);
    ki("position", s.position);
    ki("offsetX", s.offsetX);
    ki("offsetY", s.offsetY);
    ki("hideCursor", s.hideCursor ? 1 : 0);
    ki("hideFromCapture", s.hideFromCapture ? 1 : 0);
    ki("startWithWindows", s.startWithWindows ? 1 : 0);
    ki("menuKey", s.menuKey);
    ki("toggleKey", s.toggleKey);
    o += "[ui]\n";
    ki("previewBg", s.previewBg);
    ki("previewZoom", s.previewZoom);
    ki("page", s.page);
    ki("colorTarget", s.colorTarget);
    return o;
}

void parseSettings(const std::string& textIn, Settings& s) {
    CrosshairStyle& c = s.style;
    size_t pos = 0;
    while (pos < textIn.size()) {
        size_t nl = textIn.find('\n', pos);
        if (nl == std::string::npos) nl = textIn.size();
        const std::string l = trim(textIn.substr(pos, nl - pos));
        pos = nl + 1;
        if (l.empty() || l[0] == ';' || l[0] == '#' || l[0] == '[') continue;
        const size_t eq = l.find('=');
        if (eq == std::string::npos) continue;
        const std::string k = trim(l.substr(0, eq)), v = trim(l.substr(eq + 1));
        const float f = (float)std::atof(v.c_str());
        const int i = std::atoi(v.c_str());
        RGBA col;
        if (k == "blades") c.blades = clampi(i, 1, 12);
        else if (k == "length") c.length = clampf(f, 1.f, 200.f);
        else if (k == "width") c.width = clampf(f, 0.5f, 100.f);
        else if (k == "gap") c.gap = clampf(f, 0.f, 200.f);
        else if (k == "outline") c.outline = clampf(f, 0.f, 20.f);
        else if (k == "showOutline") c.showOutline = i != 0;
        else if (k == "dot") c.dot = clampf(f, 0.f, 50.f);
        else if (k == "scale") c.scale = clampf(f, 0.25f, 8.f);
        else if (k == "glow") c.glow = clampf(f, 0.f, 5.f);
        else if (k == "glowSize") c.glowSize = clampf(f, 0.25f, 5.f);
        else if (k == "halo") c.halo = clampf(f, 0.f, 5.f);
        else if (k == "shadow") c.shadow = clampf(f, 0.f, 1.f);
        else if (k == "opacity") c.opacity = clampf(f, 0.05f, 1.f);
        else if (k == "fill" && parseHex(v, col)) c.fill = col;
        else if (k == "line" && parseHex(v, col)) c.line = col;
        else if (k == "dotColor" && parseHex(v, col)) c.dotCol = col;
        else if (k == "glowColor" && parseHex(v, col)) c.glowCol = col;
        else if (k == "enabled") s.enabled = i != 0;
        else if (k == "spin") s.spin = i != 0;
        else if (k == "spinSpeed") s.spinSpeed = clampf(f, 0.f, 2000.f);
        else if (k == "spinDir") s.spinDir = clampi(i, 0, 1);
        else if (k == "clickReact") s.clickReact = clampi(i, 0, 2);
        else if (k == "rainbow") s.rainbow = i != 0;
        else if (k == "rainbowSpeed") s.rainbowSpeed = clampf(f, 0.01f, 3.f);
        else if (k == "position") s.position = clampi(i, 0, 1);
        else if (k == "offsetX") s.offsetX = clampi(i, -500, 500);
        else if (k == "offsetY") s.offsetY = clampi(i, -500, 500);
        else if (k == "hideCursor") s.hideCursor = i != 0;
        else if (k == "hideFromCapture") s.hideFromCapture = i != 0;
        else if (k == "startWithWindows") s.startWithWindows = i != 0;
        else if (k == "menuKey") { if (i >= 3 && i <= 254 && i != 0x1B) s.menuKey = i; }  // never a primary mouse button
        else if (k == "toggleKey") s.toggleKey = (i >= 3 && i <= 254 && i != 0x1B) ? i : 0;
        else if (k == "previewBg") s.previewBg = clampi(i, 0, 3);
        else if (k == "previewZoom") s.previewZoom = clampi(i, 1, 4);
        else if (k == "page") s.page = clampi(i, 0, 4);
        else if (k == "colorTarget") s.colorTarget = clampi(i, 0, 3);
    }
}

}  // namespace vx
