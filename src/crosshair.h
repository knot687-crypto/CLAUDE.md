// Vortex Crosshair - crosshair model + software renderer (portable C++17)
//
// The default style is a 1:1 reconstruction of the reference crosshair:
// four rhombus ("kite") blades with a white outline and a #FFC8D2 pink core,
// a white centre dot with a soft halo, and a white glow whose shape was
// recovered by fitting a model to the reference screenshot pixel by pixel
// (see tools/fit_reference.py).
#pragma once
#include <cstdint>
#include <vector>

namespace vx {

struct RGBA {  // straight (non premultiplied) sRGB, 0..1
    float r = 1, g = 1, b = 1, a = 1;
};

inline RGBA rgb8(int r, int g, int b, float a = 1.f) { return RGBA{r / 255.f, g / 255.f, b / 255.f, a}; }

// All lengths are in pixels at scale 1.0 (the size of the reference crosshair).
struct CrosshairStyle {
    int   blades   = 4;        // number of blades (reference: 4)
    float length   = 24.01f;   // blade tip-to-tip length (long diagonal)
    float width    = 6.825f;   // blade width (short diagonal)
    float gap      = 6.122f;   // distance from centre to the inner blade tip
    float outline  = 1.299f;   // outline thickness
    float dot      = 1.349f;   // centre dot radius (0 = no dot)
    float scale    = 1.0f;     // overall size multiplier
    float glow     = 1.0f;     // glow strength multiplier (0 = off)
    float glowSize = 1.0f;     // glow spread multiplier
    float halo     = 1.0f;     // centre dot halo strength multiplier
    float shadow   = 0.0f;     // dark contrast shadow strength (0 = off)
    float opacity  = 1.0f;     // global opacity
    bool  showOutline = true;
    RGBA  fill    = rgb8(255, 200, 210);
    RGBA  line    = rgb8(255, 255, 255);
    RGBA  dotCol  = rgb8(255, 255, 255);
    RGBA  glowCol = rgb8(255, 255, 255);
};

// Renders the crosshair into a premultiplied BGRA (Windows DIB order) buffer.
// The glow is pre-computed into a "master" field whenever the geometry changes
// and is sampled rotated every frame, so spinning costs almost nothing.
class CrosshairRenderer {
public:
    // Re-builds cached data if geometry/glow parameters changed.
    void prepare(const CrosshairStyle& s);
    // Radius (in pixels) of the area the crosshair can touch, glow included.
    float extent() const { return extent_; }
    // Draws over whatever is in the buffer ("over" compositing).
    // (cx, cy): centre in pixel coordinates (pixel i covers [i, i+1)).
    // angle: rotation in radians (clockwise on screen).
    // clip: optional pixel rectangle limiting the drawn area.
    // zoom: extra magnification applied at draw time (used for the click "pulse"
    //       without rebuilding the glow field).
    void render(uint32_t* px, int w, int h, int stridePx, float cx, float cy, float angle,
                const CrosshairStyle& s, int clipX0 = 0, int clipY0 = 0, int clipX1 = 1 << 30,
                int clipY1 = 1 << 30, float zoom = 1.f) const;
private:
    struct Geo {
        int blades;
        float a, b;        // outer rhombus half diagonals (along / across blade)
        float ai, bi;      // inner rhombus half diagonals (fill area)
        float m;           // distance centre -> rhombus centre
        float dot;
        bool outline;
    };
    Geo geo_{};
    float extent_ = 40.f;
    // glow master field (alpha 0..1) and shadow field on a regular grid
    std::vector<float> glowField_, shadowField_;
    int   fieldN_ = 0;       // grid is fieldN_ x fieldN_
    float fieldStep_ = 0.5f; // pixels per grid step
    float fieldOrigin_ = 0;  // coordinate (relative to centre) of grid index 0
    bool  hasShadow_ = false, hasGlow_ = false;
    // cache key
    float key_[14] = {};
    bool  valid_ = false;

    float sampleField(const std::vector<float>& f, float x, float y) const;
};

}  // namespace vx
