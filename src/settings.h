// Vortex Crosshair - user settings, presets and persistence (portable)
#pragma once
#include <string>

#include "crosshair.h"

namespace vx {

enum ClickReact { REACT_NONE = 0, REACT_SPIN = 1, REACT_PULSE = 2 };
enum PositionMode { POS_CURSOR = 0, POS_CENTER = 1 };

struct Settings {
    CrosshairStyle style;           // geometry, colours, glow (defaults = the reference crosshair)
    bool  enabled = true;           // crosshair visible
    bool  spin = true;
    float spinSpeed = 150.f;        // degrees per second
    int   spinDir = 0;              // 0 clockwise, 1 counter-clockwise
    int   clickReact = REACT_NONE;
    bool  rainbow = false;
    float rainbowSpeed = 0.20f;     // hue cycles per second
    int   position = POS_CURSOR;
    int   offsetX = 0, offsetY = 0; // pixel nudge
    bool  hideCursor = false;       // hide the Windows pointer while the menu is closed
    bool  hideFromCapture = false;  // exclude overlay from screen capture
    bool  startWithWindows = false;
    int   menuKey = 0xA1;           // VK_RSHIFT
    int   toggleKey = 0;            // 0 = unbound
    int   previewBg = 0;            // settings preview background
    int   previewZoom = 2;          // preview magnification
    int   page = 0;                 // last open settings page
    int   colorTarget = 0;          // 0 blades, 1 outline, 2 dot, 3 glow
};

// Colour presets (theme chips in the menu).
struct ColorPreset {
    const char* name;
    RGBA fill, line, dot, glow;
};
int presetCount();
const ColorPreset& preset(int i);
void applyPreset(Settings& s, int i);
int matchPreset(const Settings& s);  // -1 if none

// Restore only the crosshair look (shape + colours + effects) to the original.
void resetLook(Settings& s);

// INI-style text (file I/O lives in the platform layer so Unicode paths work).
std::string serializeSettings(const Settings& s);
void parseSettings(const std::string& text, Settings& s);

// Human readable name for a Windows virtual-key code.
std::string keyName(int vk);

// Style actually drawn at time t (applies rainbow hue cycling).
CrosshairStyle effectiveStyle(const Settings& s, double t);

// Colour helpers
std::string toHex(const RGBA& c, bool withAlpha = false);
bool parseHex(const std::string& s, RGBA& out);  // accepts RGB / RRGGBB / RRGGBBAA, optional '#'
void rgbToHsv(const RGBA& c, float& h, float& s, float& v);
RGBA hsvToRgb(float h, float s, float v, float a = 1.f);

}  // namespace vx
