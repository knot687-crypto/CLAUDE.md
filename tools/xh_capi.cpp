// C API used by tools/fit_reference.py to evaluate the production renderer.
#include "../src/crosshair.h"
#include <vector>
#include <cstdint>
extern "C" void xh_render(const float* p, int w, int h, float cx, float cy, float angle, int bg,
                          uint8_t* outRGB) {
    vx::CrosshairStyle s;
    s.length = p[0]; s.width = p[1]; s.gap = p[2]; s.outline = p[3]; s.dot = p[4];
    s.glow = p[5]; s.glowSize = p[6]; s.halo = p[7]; s.scale = p[8];
    vx::CrosshairRenderer r;
    r.prepare(s);
    std::vector<uint32_t> buf((size_t)w * h, 0);
    r.render(buf.data(), w, h, w, cx, cy, angle, s);
    for (int i = 0; i < w * h; ++i) {
        uint32_t d = buf[i];
        float a = (d >> 24) / 255.f;
        int b = d & 255, g = (d >> 8) & 255, rr = (d >> 16) & 255;
        outRGB[3 * i + 0] = (uint8_t)(rr + bg * (1 - a) + 0.5f);
        outRGB[3 * i + 1] = (uint8_t)(g + bg * (1 - a) + 0.5f);
        outRGB[3 * i + 2] = (uint8_t)(b + bg * (1 - a) + 0.5f);
    }
}
