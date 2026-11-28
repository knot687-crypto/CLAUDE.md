// Vortex Crosshair - immediate mode glass settings panel (portable)
#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "canvas.h"
#include "crosshair.h"
#include "settings.h"

namespace vx {

struct UIInput {
    float mx = -1e6f, my = -1e6f;  // mouse position in window pixels
    bool mouseDown = false, mousePressed = false, mouseReleased = false;
    bool doubleClick = false;
    float wheel = 0.f;             // notches, positive = up
    std::string typed;             // UTF-8 text typed this frame
    bool kBack = false, kDelete = false, kEnter = false, kEscape = false, kLeft = false, kRight = false;
    bool kHome = false, kEnd = false, kSelectAll = false, kCopy = false, kPaste = false;
    std::string clipboard;         // filled by the platform when kPaste is set
    double time = 0.0;             // seconds
    float dt = 1.f / 60.f;
    bool active = true;            // window has focus
};

enum UICursor { CURSOR_ARROW = 0, CURSOR_HAND = 1, CURSOR_IBEAM = 2 };

struct UIActions {
    bool hideMenu = false;
    bool quit = false;
    bool settingsChanged = false;
    int  bindKey = 0;           // 1 = capture menu key, 2 = capture toggle key
    bool cancelBind = false;
    bool clearToggleKey = false;
    std::string copyText;       // put on clipboard
    int  cursor = CURSOR_ARROW;
};

struct AppStatus {
    int  capturing = 0;          // 1 menu key, 2 toggle key (waiting for a key press)
    bool glassBackdrop = true;   // OS blur active behind the window
    int  glassLevel = 2;         // 0 none, 1 plain blur (Win10), 2 acrylic/mica (Win11)
    float crosshairAngle = 0.f;  // live angle from the overlay (radians)
    std::string version = "1.1.0";
};

class SettingsPanel {
public:
    static constexpr float kWidth = 960.f;   // DIPs
    static constexpr float kHeight = 620.f;

    // Builds and draws one frame. `scale` = DPI scale (1.0 at 96 DPI).
    void frame(Canvas& cv, float scale, const UIInput& in, Settings& st, UIActions& out, const AppStatus& status);
    // True while something is animating and the window should keep redrawing.
    bool animating() const { return animating_ || previewAnimating_; }
    // Region of the window that changed in the last frame (window pixels).
    Rc dirtyRect() const { return dirty_; }
    // Hit test for the window drag area (header without buttons), in window pixels.
    bool dragArea(float x, float y) const;
    // Force the next frame to be a full redraw.
    void invalidate() { fullDirty_ = true; }
    void resetInteraction();
    // Call when the menu is shown: plays the entrance animation.
    void onOpen(double time) { openTime_ = time; fullDirty_ = true; }
    // A text field currently has keyboard focus (Esc should not close the menu).
    bool textFocused() const { return focus_ != 0; }

private:
    struct Spring {
        float x = 0, v = 0;
    };
    struct Ripple {
        double t0 = -10;
        float x = 0, y = 0;
    };
    struct ImageCache {  // pre-rendered static image (premultiplied BGRA)
        std::vector<uint32_t> px;
        std::string key;
        int w = 0, h = 0;
    };

    // ---- frame state
    Canvas* cv_ = nullptr;
    float s_ = 1.f;
    UIInput in_;
    UIActions* out_ = nullptr;
    Settings* st_ = nullptr;
    const AppStatus* status_ = nullptr;
    uint32_t hot_ = 0, active_ = 0, focus_ = 0;
    bool animating_ = false, previewAnimating_ = false, fullDirty_ = true;
    Rc previewPx_{}, dirty_{};
    float lastMx_ = -1e9f, lastMy_ = -1e9f;
    bool lastDown_ = false;
    float lastScale_ = 0.f;
    std::string lastSettings_;
    double armedAt_ = -10.0;
    double openTime_ = -10.0;
    double lastChange_ = -10.0;
    bool bindHovered_ = false;
    std::vector<Rc> headerHits_;
    std::unordered_map<uint32_t, float> anim_;
    std::unordered_map<uint32_t, Spring> springs_;
    std::unordered_map<uint32_t, Ripple> ripples_;
    RGBA accent_{}, accentDeep_{}, accentText_{}, accentAlt_{};
    double pageSwitchTime_ = -10.0;
    int prevPage_ = 0;
    // tooltip
    uint32_t tipId_ = 0;
    double tipStart_ = 0;
    std::string tipText_;
    Rc tipAnchor_{};
    bool tipWanted_ = false;
    // cached static glass background and gradient images
    std::vector<uint32_t> bgCache_;
    std::string bgKey_;
    ImageCache pvBgCache_, svCache_, hueCache_, alphaCache_;
    // static decorations (cards, preview shadow) baked on top of the glass for the current page
    std::vector<uint32_t> bakeCache_;
    std::string bakeKey_;
    bool baking_ = false, cardsBaked_ = false;
    // colour picker state (kept in HSV so hue survives grey colours)
    float pickH_ = 0, pickS_ = 0, pickV_ = 1;
    RGBA pickLast_{-1, -1, -1, -1};
    int pickTarget_ = -1;
    // hex text field
    std::string hexEdit_;
    size_t caret_ = 0;
    bool hexSelectAll_ = false;
    double caretTime_ = 0;
    // previews
    CrosshairRenderer previewRenderer_, chipRenderer_, logoRenderer_;
    std::vector<uint32_t> previewBuf_;
    float previewAngle_ = 0.f;
    float hoverChipAngle_[16] = {};

    // ---- helpers
    Rc R(float x, float y, float w, float h) const { return Rc{x * s_, y * s_, w * s_, h * s_}; }
    float S(float v) const { return v * s_; }
    float px1() const { return S(1.f) < 1.f ? 1.f : S(1.f); }
    float anim(uint32_t id, float target, float speed = 14.f);
    float spring(uint32_t id, float target, float stiffness = 190.f, float damping = 19.f);
    bool hovered(const Rc& r) const;
    bool behave(uint32_t id, const Rc& r, bool* hover = nullptr, bool* held = nullptr);
    void label(float x, float y, const std::string& t, float size, int face, const RGBA& c, float tracking = 0.f);
    void changed();
    float enter(float delay) const;  // entrance animation progress for a section
    void ripple(uint32_t id, const Rc& r, float radius, const RGBA& c);
    void tooltip(uint32_t id, const Rc& anchor, const std::string& text);
    void drawTooltip();

    // ---- widgets
    bool toggle(uint32_t id, const Rc& r, bool& v);
    bool slider(uint32_t id, const Rc& r, float& v, float lo, float hi, float step = 0.f);
    bool segmented(uint32_t id, const Rc& r, const std::vector<std::string>& items, int& sel, float fontSize = 12.5f);
    bool button(uint32_t id, const Rc& r, const std::string& text, int style = 0, int icon = -1);
    bool iconButton(uint32_t id, const Rc& r, int icon, const std::string& tip);
    void keycap(const Rc& r, const std::string& text, bool glowing);
    void icon(int which, float cx, float cy, float size, const RGBA& c);
    void iconTile(int which, const Rc& r, int palette, float glow);
    void card(const Rc& r, float radius = 16.f);
    void valuePill(float right, float y, const std::string& v);
    void microLabel(float x, float y, const std::string& t);
    void sliderRow(uint32_t id, float x, float y, float w, const std::string& name, const std::string& value,
                   float& v, float lo, float hi, float step = 0.f);
    void toggleRow(uint32_t id, float x, float y, float w, const std::string& name, const std::string& desc, bool& v);

    // ---- sections
    void buildBackground();
    void bakeStatic();
    void drawHeader();
    void drawSidebar();
    void drawPreview();
    void drawThemes();
    void pageColors(float x, float y, float w);
    void pageShape(float x, float y, float w);
    void pageMotion(float x, float y, float w);
    void pageEffects(float x, float y, float w);
    void pageSettings(float x, float y, float w);
    void colorPicker(float x, float y, float w, RGBA& color);
    void hexField(uint32_t id, const Rc& r, RGBA& color);
    void computeAccent();
    void paintPreviewBackground(Canvas& cv, const Rc& r, int bg);
    template <class F>
    void cachedImage(ImageCache& c, const char* tag, const Rc& r, const std::string& key, F&& paint);
};

}  // namespace vx
