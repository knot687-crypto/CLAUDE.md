// Linux/macOS design harness: renders the settings panel (over a fake blurred
// desktop) and the crosshair to PNG files, so the UI can be iterated on without
// Windows. Build: see build.sh (target "preview").
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../src/canvas.h"
#include "../src/crosshair.h"
#include "../src/settings.h"
#include "../src/ui.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../third_party/stb_image_write.h"

using namespace vx;

static void savePNG(const char* path, const std::vector<uint32_t>& px, int w, int h) {
    std::vector<uint8_t> rgba((size_t)w * h * 4);
    for (int i = 0; i < w * h; ++i) {
        const uint32_t p = px[i];
        const float a = (p >> 24) / 255.f;
        auto un = [&](int c) { return a > 0 ? (int)std::min(255.f, c / a + 0.5f) : 0; };
        rgba[4 * i + 0] = (uint8_t)un((p >> 16) & 255);
        rgba[4 * i + 1] = (uint8_t)un((p >> 8) & 255);
        rgba[4 * i + 2] = (uint8_t)un(p & 255);
        rgba[4 * i + 3] = (uint8_t)(p >> 24);
    }
    stbi_write_png(path, w, h, 4, rgba.data(), w * 4);
}

// Fake desktop: colourful wallpaper, heavily blurred and darkened (= Windows 11 acrylic).
static std::vector<float> desktop(int w, int h, int variant) {
    std::vector<float> img((size_t)w * h * 3);
    struct Blob { float x, y, r, cr, cg, cb; };
    std::vector<Blob> blobs;
    if (variant == 0)
        blobs = {{0.15f, 0.2f, 0.45f, 0.95f, 0.35f, 0.55f}, {0.8f, 0.25f, 0.5f, 0.25f, 0.45f, 1.f},
                 {0.55f, 0.85f, 0.55f, 0.2f, 0.85f, 0.75f}, {0.95f, 0.9f, 0.3f, 1.f, 0.7f, 0.3f}};
    else
        blobs = {{0.3f, 0.3f, 0.6f, 0.9f, 0.9f, 0.95f}, {0.8f, 0.7f, 0.6f, 0.7f, 0.8f, 0.95f}};
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            float r = variant == 0 ? 0.08f : 0.75f, g = variant == 0 ? 0.08f : 0.78f, b = variant == 0 ? 0.12f : 0.85f;
            for (auto& bl : blobs) {
                const float dx = x / (float)w - bl.x, dy = y / (float)h - bl.y;
                const float k = std::exp(-(dx * dx + dy * dy) / (bl.r * bl.r));
                r += bl.cr * k * 0.8f; g += bl.cg * k * 0.8f; b += bl.cb * k * 0.8f;
            }
            float* o = &img[((size_t)y * w + x) * 3];
            o[0] = std::min(1.f, r); o[1] = std::min(1.f, g); o[2] = std::min(1.f, b);
        }
    return img;
}

int main(int argc, char** argv) {
    const char* out = argc > 1 ? argv[1] : "ui.png";
    const int page = argc > 2 ? std::atoi(argv[2]) : 0;
    const float scale = argc > 3 ? (float)std::atof(argv[3]) : 1.f;
    const float mx = argc > 4 ? (float)std::atof(argv[4]) : -1000.f;
    const float my = argc > 5 ? (float)std::atof(argv[5]) : -1000.f;
    const int variant = argc > 6 ? std::atoi(argv[6]) : 0;
    const bool glass = argc > 7 ? std::atoi(argv[7]) != 0 : true;
    const int preset = argc > 8 ? std::atoi(argv[8]) : 0;
    const float openAt = argc > 9 ? (float)std::atof(argv[9]) : -1.f;  // render the entrance animation at t seconds

    text().init();
    Settings st;
    st.page = page;
    if (preset > 0) applyPreset(st, preset);
    if (variant == 2) { st.previewBg = 1; st.previewZoom = 2; }
    const int W = (int)std::ceil(SettingsPanel::kWidth * scale), H = (int)std::ceil(SettingsPanel::kHeight * scale);
    std::vector<uint32_t> buf((size_t)W * H, 0);
    Canvas cv;
    cv.attach(buf.data(), W, H, W);
    SettingsPanel panel;
    AppStatus status;
    status.glassBackdrop = glass;
    UIInput in;
    in.mx = mx * scale;
    in.my = my * scale;
    if (openAt >= 0.f) panel.onOpen(10.0 + 90 / 60.0 - openAt);
    if (getenv("BENCH")) {
        // time full redraws and preview-only redraws
        auto now = [] { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); };
        UIInput bi;
        double t0 = now();
        for (int f = 0; f < 60; ++f) {
            bi.time = 100.0 + f / 60.0;
            panel.invalidate();
            UIActions a;
            panel.frame(cv, scale, bi, st, a, status);
        }
        double t1 = now();
        for (int f = 0; f < 60; ++f) {
            bi.time = 200.0 + f / 60.0;
            UIActions a;
            panel.frame(cv, scale, bi, st, a, status);
        }
        double t2 = now();
        std::printf("full redraw: %.2f ms/frame, preview-only: %.2f ms/frame (scale %.2f)\n", (t1 - t0) / 60 * 1000,
                    (t2 - t1) / 60 * 1000, scale);
        return 0;
    }
    const bool press = getenv("PRESS") != nullptr;
    for (int f = 0; f < 90; ++f) {
        in.time = 10.0 + f / 60.0;
        in.dt = 1.f / 60.f;
        in.mousePressed = press && f == 75;
        in.mouseDown = press && f >= 75;
        UIActions act;
        panel.frame(cv, scale, in, st, act, status);
    }
    // composite over fake acrylic desktop
    const int M = (int)(40 * scale);
    const int DW = W + 2 * M, DH = H + 2 * M;
    std::vector<float> desk = desktop(DW, DH, variant == 1 ? 1 : 0);
    std::vector<uint32_t> comp((size_t)DW * DH);
    for (int y = 0; y < DH; ++y)
        for (int x = 0; x < DW; ++x) {
            const float* d = &desk[((size_t)y * DW + x) * 3];
            float r = d[0], g = d[1], b = d[2];
            const int wx = x - M, wy = y - M;
            const bool inside = wx >= 0 && wy >= 0 && wx < W && wy < H;
            if (inside) {
                // window drop shadow is drawn by DWM; acrylic = blurred desktop + tint + luminosity
                if (glass) {
                    const float l = 0.3f * r + 0.6f * g + 0.1f * b;
                    r = r * 0.55f + l * 0.25f + 0.02f; g = g * 0.55f + l * 0.25f + 0.02f; b = b * 0.55f + l * 0.25f + 0.03f;
                    r *= 0.55f; g *= 0.55f; b *= 0.6f;
                }
                const uint32_t p = buf[(size_t)wy * W + wx];
                const float a = (p >> 24) / 255.f;
                r = ((p >> 16) & 255) / 255.f + r * (1 - a);
                g = ((p >> 8) & 255) / 255.f + g * (1 - a);
                b = (p & 255) / 255.f + b * (1 - a);
            } else {
                // soft DWM-like shadow around the window
                const float dx = std::max({0.f, (float)-wx, (float)(wx - W + 1)});
                const float dy = std::max({0.f, (float)-wy + 6.f * scale, (float)(wy - H + 1) - 6.f * scale});
                const float dd = std::sqrt(dx * dx + dy * dy) / (22.f * scale);
                const float sh = 0.55f * std::exp(-dd * dd * 2.5f);
                r *= 1 - sh; g *= 1 - sh; b *= 1 - sh;
            }
            comp[(size_t)y * DW + x] = 0xFF000000u | ((uint32_t)(std::min(1.f, r) * 255.f) << 16) |
                                       ((uint32_t)(std::min(1.f, g) * 255.f) << 8) | (uint32_t)(std::min(1.f, b) * 255.f);
        }
    savePNG(out, comp, DW, DH);
    std::printf("wrote %s (%dx%d)\n", out, DW, DH);
    return 0;
}
