// Renders the application icon (the real crosshair on a glass tile) at every
// standard size and packs it into res/vortex.ico (BMP entries + 256px PNG).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "../src/canvas.h"
#include "../src/crosshair.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../third_party/stb_image_write.h"

using namespace vx;

static std::vector<uint32_t> renderIcon(int size) {
    std::vector<uint32_t> px((size_t)size * size, 0);
    Canvas cv;
    cv.attach(px.data(), size, size, size);
    const float s = size / 32.f;
    const Rc tile{0.5f * s, 0.5f * s, size - 1.f * s, size - 1.f * s};
    cv.fillRoundRectGrad(tile, 8.f * s, RGBA{0.17f, 0.16f, 0.21f, 1}, RGBA{0.05f, 0.05f, 0.07f, 1});
    if (size >= 48) cv.glowBlob(size * 0.5f, size * 0.5f, size * 0.42f, size * 0.42f, RGBA{1.f, 0.55f, 0.68f, 0.16f});
    cv.strokeRoundRectGrad(tile, 8.f * s, std::max(1.f, 1.f * s), RGBA{1, 1, 1, 0.28f}, RGBA{1, 1, 1, 0.06f});
    CrosshairStyle st;
    st.scale = size / 62.f;
    st.glow = size >= 24 ? 1.f : 0.6f;
    CrosshairRenderer r;
    r.prepare(st);
    r.render(px.data(), size, size, size, size * 0.5f, size * 0.5f, -0.3175f, st);
    return px;
}

static void toStraightRGBA(const std::vector<uint32_t>& px, std::vector<uint8_t>& rgba) {
    rgba.resize(px.size() * 4);
    for (size_t i = 0; i < px.size(); ++i) {
        const uint32_t p = px[i];
        const uint32_t a = p >> 24;
        auto un = [&](uint32_t c) { return a ? (uint8_t)std::min<uint32_t>(255, (c * 255 + a / 2) / a) : (uint8_t)0; };
        rgba[4 * i + 0] = un((p >> 16) & 255);
        rgba[4 * i + 1] = un((p >> 8) & 255);
        rgba[4 * i + 2] = un(p & 255);
        rgba[4 * i + 3] = (uint8_t)a;
    }
}

static void put16(std::vector<uint8_t>& v, uint16_t x) { v.push_back(x & 255); v.push_back(x >> 8); }
static void put32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back((x >> (8 * i)) & 255); }
static void pngWriter(void* ctx, void* data, int size) {
    auto* v = (std::vector<uint8_t>*)ctx;
    v->insert(v->end(), (uint8_t*)data, (uint8_t*)data + size);
}

int main(int argc, char** argv) {
    const char* out = argc > 1 ? argv[1] : "res/vortex.ico";
    const char* png = argc > 2 ? argv[2] : nullptr;
    const int sizes[] = {16, 20, 24, 32, 40, 48, 64, 96, 128, 256};
    const int n = sizeof(sizes) / sizeof(sizes[0]);
    std::vector<std::vector<uint8_t>> blobs;
    for (int size : sizes) {
        std::vector<uint32_t> px = renderIcon(size);
        std::vector<uint8_t> rgba;
        toStraightRGBA(px, rgba);
        std::vector<uint8_t> blob;
        if (size >= 256) {
            stbi_write_png_to_func(pngWriter, &blob, size, size, 4, rgba.data(), size * 4);
        } else {
            // BITMAPINFOHEADER + bottom-up BGRA + empty AND mask
            put32(blob, 40); put32(blob, (uint32_t)size); put32(blob, (uint32_t)(size * 2));
            put16(blob, 1); put16(blob, 32); put32(blob, 0);
            const int maskStride = ((size + 31) / 32) * 4;
            put32(blob, (uint32_t)(size * size * 4 + maskStride * size));
            put32(blob, 0); put32(blob, 0); put32(blob, 0); put32(blob, 0);
            for (int y = size - 1; y >= 0; --y)
                for (int x = 0; x < size; ++x) {
                    const uint8_t* p = &rgba[((size_t)y * size + x) * 4];
                    blob.push_back(p[2]); blob.push_back(p[1]); blob.push_back(p[0]); blob.push_back(p[3]);
                }
            blob.insert(blob.end(), (size_t)maskStride * size, 0);
        }
        blobs.push_back(blob);
        if (png && size == 256) stbi_write_png(png, size, size, 4, rgba.data(), size * 4);
    }
    std::vector<uint8_t> ico;
    put16(ico, 0); put16(ico, 1); put16(ico, (uint16_t)n);
    uint32_t offset = 6 + 16 * n;
    for (int i = 0; i < n; ++i) {
        ico.push_back(sizes[i] >= 256 ? 0 : (uint8_t)sizes[i]);
        ico.push_back(sizes[i] >= 256 ? 0 : (uint8_t)sizes[i]);
        ico.push_back(0); ico.push_back(0);
        put16(ico, 1); put16(ico, 32);
        put32(ico, (uint32_t)blobs[i].size()); put32(ico, offset);
        offset += (uint32_t)blobs[i].size();
    }
    for (auto& b : blobs) ico.insert(ico.end(), b.begin(), b.end());
    FILE* f = std::fopen(out, "wb");
    if (!f) return 1;
    std::fwrite(ico.data(), 1, ico.size(), f);
    std::fclose(f);
    std::printf("wrote %s (%zu bytes, %d sizes)\n", out, ico.size(), n);
    return 0;
}
