#include "surfaces.h"

#include "canvas.h"
#include "colour.h"

#include <algorithm>
#include <cmath>
#include <functional>

namespace hive {

namespace {

// The grid a pattern is composed on and the texels it is resolved at differ: detail under a texel is shimmer.
const int GRID = 128;
const int WEAVE = 256;

// Seeded, so a surface comes out the same every time and its grain and relief are one drawing.
uint32_t dice = 1;

void seed(const std::string& text) {
    uint32_t h = 2166136261u;
    for (char c : text) {
        h ^= uint8_t(c);
        h *= 16777619u;
    }
    dice = h;
}

float rnd() {
    dice += 0x6D2B79F5u;
    uint32_t t = (dice ^ (dice >> 15)) * (dice | 1u);
    t ^= t + (t ^ (t >> 7)) * (t | 61u);
    return float(double(t ^ (t >> 14)) / 4294967296.0);
}

void grit(Canvas& cv, int cells, float amount) {
    int size = cv.size();
    std::vector<float> lattice(size_t(cells) * cells);
    for (auto& v : lattice) { v = rnd() * 2 - 1; }
    float step = float(cells) / float(size);
    for (int y = 0; y < size; y++) {
        float fy = float(y) * step;
        int y0 = int(std::floor(fy));
        float ty = fy - float(y0);
        ty = ty * ty * (3 - 2 * ty);
        int r0 = (y0 % cells) * cells, r1 = ((y0 + 1) % cells) * cells;
        for (int x = 0; x < size; x++) {
            float fx = float(x) * step;
            int x0 = int(std::floor(fx));
            float tx = fx - float(x0);
            tx = tx * tx * (3 - 2 * tx);
            int c0 = x0 % cells, c1 = (x0 + 1) % cells;
            float n = (lattice[r0 + c0] * (1 - tx) + lattice[r0 + c1] * tx) * (1 - ty) +
                (lattice[r1 + c0] * (1 - tx) + lattice[r1 + c1] * tx) * ty;
            float k = 1 + n * amount;
            uint8_t p[4];
            cv.read(y * size + x, p);
            for (int c = 0; c < 3; c++) {
                p[c] = uint8_t(std::min(255.0f, std::max(0.0f, std::nearbyint(float(p[c]) * k))));
            }
            cv.write(y * size + x, p);
        }
    }
}

void around(float size, float x, float y, float reach, const std::function<void(float, float)>& draw) {
    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            float px = x + float(dx) * size, py = y + float(dy) * size;
            if (px > -reach && px < size + reach && py > -reach && py < size + reach) { draw(px, py); }
        }
    }
}

void dot(Canvas& cv, float size, float x, float y, float r, Ink style) {
    around(size, x, y, r, [&](float px, float py) { cv.disc(px, py, r, style); });
}

void line(Canvas& cv, float x0, float y0, float x1, float y1, float thick, Ink style) {
    cv.stroke({x0, y0, x1, y1}, thick, style);
}

void turf(Canvas& cv, float size) {
    grit(cv, 4, 0.12f);
    grit(cv, 12, 0.10f);
    grit(cv, 48, 0.08f);
    for (int i = 0; i < 900; i++) {
        float x = rnd() * size;
        float y = rnd() * size;
        float lean = (rnd() - 0.5f) * 3;
        float tall = 2 + rnd() * 3.5f;
        Ink style = i % 3 == 0 ? ink(255, 255, 220, 0.22f) : black(0.20f);
        around(size, x, y, 6, [&](float px, float py) { line(cv, px, py, px + lean, py - tall, 0.7f, style); });
    }
}

void planks(Canvas& cv, float size) {
    grit(cv, 6, 0.06f);
    int boards = 4;
    float high = size / float(boards);
    for (int b = 0; b < boards; b++) {
        float tone = rnd() - 0.5f;
        cv.rect(0, float(b) * high, size, high, tone < 0 ? black(-tone * 0.22f) : white(tone * 0.16f));
        for (int s = 0; s < 14; s++) {
            float y = float(b) * high + 2 + rnd() * (high - 4);
            float wave = rnd() * 2;
            float thick = 0.5f + rnd();
            cv.curve(0, y, size * 0.3f, y + wave, size * 0.7f, y - wave, size, y, thick,
                s % 2 ? black(0.10f) : white(0.07f));
        }
        cv.rect(0, float(b) * high, size, 1.2f, black(0.38f));
        cv.rect(0, float(b) * high + 1.2f, size, 0.8f, white(0.12f));
    }
    grit(cv, 64, 0.05f);
}

void staves(Canvas& cv, float size) {
    grit(cv, 6, 0.06f);
    int count = 8;
    float wide = size / float(count);
    for (int i = 0; i < count; i++) {
        float tone = rnd() - 0.5f;
        cv.rect(float(i) * wide, 0, wide, size, tone < 0 ? black(-tone * 0.2f) : white(tone * 0.14f));
        for (int s = 0; s < 5; s++) {
            float at = float(i) * wide + 1 + rnd() * (wide - 2);
            cv.rect(at, 0, 0.6f, size, s % 2 ? black(0.08f) : white(0.06f));
        }
        cv.rect(float(i) * wide, 0, 1.2f, size, black(0.30f));
    }
    grit(cv, 64, 0.05f);
}

void tarmac(Canvas& cv, float size) {
    grit(cv, 3, 0.07f);
    grit(cv, 16, 0.07f);
    grit(cv, 96, 0.10f);
    for (int i = 0; i < 1600; i++) {
        float x = rnd() * size;
        float y = rnd() * size;
        float r = 0.25f + rnd() * 0.6f;
        dot(cv, size, x, y, r, i % 3 == 0 ? white(0.20f) : black(0.18f));
    }
}

void kerb(Canvas& cv, Canvas& mine, float size) {
    grit(cv, 8, 0.08f);
    grit(cv, 64, 0.06f);
    std::vector<std::vector<float>> stripes;
    for (int i = -2; i < 4; i++) {
        float x = size * float(i) / 2;
        stripes.push_back({x, 0, x + size / 4, 0, x + size / 4 + size, size, x + size, size});
    }
    mine.shapes(stripes, ink(0xe8, 0xe6, 0xe0));
    cv.rect(0, 0, 1, size, black(0.3f));
}

void gravel(Canvas& cv, float size) {
    grit(cv, 8, 0.08f);
    cv.rect(0, 0, size, size, black(0.12f));
    for (int i = 0; i < 520; i++) {
        float x = rnd() * size;
        float y = rnd() * size;
        float r = 0.8f + rnd() * 1.8f;
        float tone = rnd() * 0.18f;
        dot(cv, size, x, y + r * 0.35f, r, black(0.22f));
        dot(cv, size, x, y, r, white(0.10f + tone));
        dot(cv, size, x - r * 0.3f, y - r * 0.3f, r * 0.45f, white(0.12f));
    }
    grit(cv, 64, 0.06f);
}

void metal(Canvas& cv, float size) {
    grit(cv, 4, 0.04f);
    for (int i = 0; i < 220; i++) {
        float y = rnd() * size;
        line(cv, 0, y, size, y, 0.5f, i % 2 ? white(0.06f) : black(0.06f));
    }
}

void carbon(Canvas& cv, float size) {
    int cells = 16;
    float cell = size / float(cells);
    for (int y = 0; y < cells; y++) {
        for (int x = 0; x < cells; x++) {
            bool over = (x + y) % 2 == 0;
            cv.rect(float(x) * cell, float(y) * cell, cell, cell, over ? white(0.055f) : black(0.11f));
            Ink thread = over ? white(0.05f) : black(0.07f);
            for (int i = 1; i < 3; i++) {
                float third = cell * float(i) / 3;
                if (over) {
                    line(cv, float(x) * cell, float(y) * cell + third, float(x) * cell + cell, float(y) * cell + third,
                        1, thread);
                } else {
                    line(cv, float(x) * cell + third, float(y) * cell, float(x) * cell + third, float(y) * cell + cell,
                        1, thread);
                }
            }
        }
    }
}

void gloss(Canvas& cv, float) { grit(cv, 64, 0.02f); }

void concrete(Canvas& cv, float size) {
    grit(cv, 3, 0.07f);
    grit(cv, 12, 0.06f);
    grit(cv, 96, 0.07f);
    for (int i = 0; i < 260; i++) {
        float x = rnd() * size;
        float y = rnd() * size;
        float r = 0.3f + rnd() * 0.5f;
        dot(cv, size, x, y, r, black(0.22f));
    }
    cv.rect(0, size / 2, size, 0.8f, black(0.22f));
    cv.rect(size / 2, 0, 0.8f, size, black(0.22f));
    cv.rect(0, size / 2 + 0.8f, size, 0.6f, white(0.10f));
}

void brick(Canvas& cv, float size) {
    int courses = 12, across = 6;
    float high = size / float(courses), wide = size / float(across);
    cv.rect(0, 0, size, size, white(0.30f));
    for (int y = 0; y < courses; y++) {
        float shift = float(y % 2) * wide / 2;
        for (int x = -1; x <= across; x++) {
            float tone = rnd() - 0.5f;
            float left = float(x) * wide + shift;
            cv.rect(left + 0.6f, float(y) * high + 0.6f, wide - 1.2f, high - 1.2f, ink(128, 128, 128, 1));
            cv.rect(left + 0.6f, float(y) * high + 0.6f, wide - 1.2f, high - 1.2f,
                tone < 0 ? black(-tone * 0.34f) : white(tone * 0.22f));
            cv.rect(left + 0.6f, float(y) * high + high - 1.4f, wide - 1.2f, 0.8f, black(0.14f));
        }
    }
    grit(cv, 32, 0.08f);
    grit(cv, 128, 0.06f);
}

void panes(Canvas& cv, Canvas& mine, float size) {
    grit(cv, 6, 0.05f);
    grit(cv, 64, 0.05f);
    float wide = size * 0.44f, high = size * 0.46f;
    float left = (size - wide) / 2, top = size * 0.2f;
    cv.rect(left - 3, top - 3, wide + 6, high + 6, black(0.30f));
    cv.rect(left - 5, top + high + 3, wide + 10, 2.4f, white(0.32f));
    cv.rect(left - 5, top + high + 5.4f, wide + 10, 1, black(0.22f));
    Ink sill = ink(0xec, 0xe8, 0xde);
    mine.rect(left - 1.5f, top - 1.5f, wide + 3, high + 3, sill);
    mine.shaded(left, top, wide, high, {0, 0.5f, 1}, {ink(0x5b, 0x6f, 0x7c), ink(0x34, 0x44, 0x4f), ink(0x28, 0x34, 0x3c)});
    mine.rect(left, top + high * 0.36f, wide, 1.6f, sill);
    mine.rect(left + wide / 2 - 0.8f, top, 1.6f, high, sill);
}

void bark(Canvas& cv, float size) {
    grit(cv, 4, 0.08f);
    grit(cv, 32, 0.10f);
    for (int i = 0; i < 34; i++) {
        float x = rnd() * size;
        float wide = 0.8f + rnd() * 2.2f;
        Ink style = i % 4 == 0 ? white(0.10f) : black(0.30f);
        float y = 0;
        while (y < size) {
            float run = 5 + rnd() * 14;
            around(size, x, y, wide, [&](float px, float py) { cv.rect(px, py, wide, run, style); });
            x = x + (rnd() - 0.5f) * 2.4f;
            y = y + run + rnd() * 2;
        }
    }
}

void leaves(Canvas& cv, float size) {
    grit(cv, 4, 0.10f);
    cv.rect(0, 0, size, size, black(0.20f));
    for (int i = 0; i < 520; i++) {
        int shade = i % 4;
        Ink style = shade == 0 ? ink(255, 255, 230, 0.20f) : shade == 1 ? white(0.10f) : shade == 2 ? black(0.18f)
            : black(0.30f);
        float x = rnd() * size;
        float y = rnd() * size;
        float r = 1.2f + rnd() * 2.6f;
        float turn = rnd() * 3.14f;
        around(size, x, y, r * 2, [&](float px, float py) { cv.oval(px, py, r, r * 0.55f, turn, style); });
    }
    grit(cv, 48, 0.08f);
}

void crowd(Canvas& cv, Canvas& mine, float size) {
    int rows = 7;
    float high = size / float(rows);
    const Ink shirts[8] = {ink(0xc9, 0x4f, 0x3d), ink(0xe8, 0xc5, 0x6a), ink(0x5b, 0x86, 0xb8), ink(0xec, 0xe8, 0xe0),
        ink(0x5f, 0x94, 0x63), ink(0xa9, 0x82, 0xc4), ink(0xc9, 0x8d, 0xa8), ink(0x41, 0x48, 0x50)};
    for (int r = 0; r < rows; r++) {
        cv.rect(0, float(r) * high, size, high, black(0.10f + float(rows - r) * 0.030f));
        cv.rect(0, float(r) * high, size, 1.5f, black(0.30f));
        for (int i = 0; i < 13; i++) {
            float x = (float(i) + 0.5f) * size / 13 + (rnd() - 0.5f) * 2.5f;
            float y = float(r) * high + high * 0.56f;
            mine.disc(x, y, high * 0.17f, shirts[(r * 5 + i * 3) % 8]);
            mine.disc(x, y - high * 0.24f, high * 0.09f, ink(0xc9, 0x9a, 0x7a));
        }
    }
}

void mesh(Canvas& cv, float size) {
    cv.clear();
    for (int pass = 0; pass < 2; pass++) {
        Ink wire = pass ? ink(90, 90, 90, 1) : ink(170, 170, 170, 1);
        for (int i = -8; i < 16; i++) {
            float at = float(i) * size / 8;
            if (pass) { line(cv, at, 0, at + size, size, 1.5f, wire); }
            else { line(cv, at, 0, at - size, size, 1.5f, wire); }
        }
    }
}

void rubber(Canvas& cv, float size) {
    grit(cv, 8, 0.05f);
    grit(cv, 96, 0.08f);
    for (int i = 0; i < 40; i++) {
        float y = rnd() * size;
        float thick = 2 + rnd() * 3;
        line(cv, 0, y, size, y, thick, black(0.09f));
    }
}

void glass(Canvas& cv, float size) {
    grit(cv, 8, 0.03f);
    cv.frame(1, 1, size - 2, size - 2, 2, black(0.35f));
}

void speckle(Canvas& cv, float size) {
    grit(cv, 6, 0.035f);
    grit(cv, 48, 0.04f);
    for (int i = 0; i < 90; i++) {
        float x = rnd() * size;
        float y = rnd() * size;
        float r = 0.5f + rnd() * 1.5f;
        dot(cv, size, x, y, r, i % 2 ? white(0.07f) : black(0.09f));
    }
}

void drawn(Canvas& cv, Canvas& mine, const std::string& finish, float size) {
    if (finish == "Turf") { turf(cv, size); }
    else if (finish == "Gravel") { gravel(cv, size); }
    else if (finish == "Tarmac") { tarmac(cv, size); }
    else if (finish == "Kerb") { kerb(cv, mine, size); }
    else if (finish == "Concrete") { concrete(cv, size); }
    else if (finish == "Brick") { brick(cv, size); }
    else if (finish == "Panes") { panes(cv, mine, size); }
    else if (finish == "Staves") { staves(cv, size); }
    else if (finish == "Bark") { bark(cv, size); }
    else if (finish == "Leaves") { leaves(cv, size); }
    else if (finish == "Crowd") { crowd(cv, mine, size); }
    else if (finish == "Mesh") { mesh(cv, size); }
    else if (finish == "Speckle") { speckle(cv, size); }
    else if (finish == "Metal") { metal(cv, size); }
    else if (finish == "Carbon") { carbon(cv, size); }
    else if (finish == "Rubber") { rubber(cv, size); }
    else if (finish == "Glass") { glass(cv, size); }
    else if (finish == "Gloss") { gloss(cv, size); }
    else { planks(cv, size); }
}

int flipped(int i, int size) { return (size - 1 - i / size) * size + i % size; }

std::vector<float> softened(const std::vector<float>& field, int size) {
    std::vector<float> mid(field.size()), out(field.size());
    for (int y = 0; y < size; y++) {
        int row = y * size;
        for (int x = 0; x < size; x++) {
            mid[row + x] = (field[row + (x + size - 1) % size] + 2 * field[row + x] + field[row + (x + 1) % size]) / 4;
        }
    }
    for (int j = 0; j < size; j++) {
        int up = ((j + size - 1) % size) * size, at = j * size, down = ((j + 1) % size) * size;
        for (int i = 0; i < size; i++) { out[at + i] = (mid[up + i] + 2 * mid[at + i] + mid[down + i]) / 4; }
    }
    return out;
}

void slope(const std::vector<float>& field, int size, std::vector<uint8_t>& b) {
    std::vector<float> high = softened(softened(field, size), size);
    const float deep = 1.2f;
    for (int y = 0; y < size; y++) {
        int up = ((y + size - 1) % size) * size, mid = y * size, down = ((y + 1) % size) * size;
        for (int x = 0; x < size; x++) {
            int l = (x + size - 1) % size, r = (x + 1) % size;
            float across = (high[up + r] + 2 * high[mid + r] + high[down + r]) -
                (high[up + l] + 2 * high[mid + l] + high[down + l]);
            float along = (high[down + l] + 2 * high[down + x] + high[down + r]) -
                (high[up + l] + 2 * high[up + x] + high[up + r]);
            float nx = -across * deep, ny = along * deep;
            float len = std::sqrt(nx * nx + ny * ny + 1);
            int to = flipped(mid + x, size) * 4;
            b[to] = uint8_t((nx / len * 0.5f + 0.5f) * 255);
            b[to + 1] = uint8_t((ny / len * 0.5f + 0.5f) * 255);
            b[to + 2] = uint8_t((1 / len * 0.5f + 0.5f) * 255);
            b[to + 3] = 255;
        }
    }
}

uint8_t encode8(float v) { return uint8_t(std::nearbyint(255 * encoded(v))); }

} // namespace

Look lookOf(const std::string& f) {
    if (f == "Turf") { return {0.95f, 0, 0.6f}; }
    if (f == "Gravel") { return {0.9f, 0, 0.8f}; }
    if (f == "Tarmac") { return {0.86f, 0, 0.45f}; }
    if (f == "Kerb") { return {0.8f, 0, 0.45f}; }
    if (f == "Concrete") { return {0.88f, 0, 0.45f}; }
    if (f == "Brick") { return {0.85f, 0, 0.7f}; }
    if (f == "Panes") { return {0.82f, 0, 0.45f}; }
    if (f == "Staves") { return {0.72f, 0, 0.55f}; }
    if (f == "Bark") { return {0.95f, 0, 0.9f}; }
    if (f == "Leaves") { return {0.8f, 0, 0.8f}; }
    if (f == "Crowd") { return {0.9f, 0, 0.35f}; }
    if (f == "Mesh") { return {0.45f, 0.4f, 0}; }
    if (f == "Speckle") { return {0.9f, 0, 0.3f}; }
    if (f == "Metal") { return {0.4f, 0.4f, 0.25f}; }
    if (f == "Carbon") { return {0.35f, 0.1f, 0.4f}; }
    if (f == "Rubber") { return {0.92f, 0, 0.45f}; }
    if (f == "Glass") { return {0.05f, 0, 0}; }
    if (f == "Gloss") { return {0.24f, 0, 0}; }
    return {0.72f, 0, 0.55f};
}

bool bumped(const std::string& finish) { return finish != "Gloss" && finish != "Glass" && finish != "Mesh"; }

bool broad(const std::string& f) {
    return f == "Turf" || f == "Gravel" || f == "Tarmac" || f == "Concrete" || f == "Leaves" || f == "Speckle" ||
        f == "Bark";
}

float perTile(const std::string& finish) { return finish == "Panes" ? 2.9f : 2.0f; }

Skin weave(const std::string& finish, const Picture* shot, const Picture* dug) {
    const int size = WEAVE;
    Canvas paper(size), pane(size);
    if (shot && !shot->empty()) {
        paper.picture(shot->rgba.data(), shot->wide, shot->tall);
    } else {
        paper.flood(ink(128, 128, 128));
        seed(finish);
        paper.scaled(float(size) / float(GRID));
        pane.scaled(float(size) / float(GRID));
        drawn(paper, pane, finish, float(GRID));
    }
    Skin skin;
    skin.size = size;
    skin.grain.assign(size_t(size) * size * 4, 0);
    std::vector<float> high(size_t(size) * size);
    std::vector<uint8_t> first(size_t(size) * size * 4), second(size_t(size) * size * 4);
    double sum = 0;
    int weight = 0;
    for (int i = 0; i < size * size; i++) {
        uint8_t* a = &first[size_t(i) * 4];
        uint8_t* b = &second[size_t(i) * 4];
        paper.read(i, a);
        pane.read(i, b);
        float o = float(b[3]) / 255.0f;
        float r = float(a[0]) + (float(b[0]) - float(a[0])) * o;
        float g = float(a[1]) + (float(b[1]) - float(a[1])) * o;
        float bl = float(a[2]) + (float(b[2]) - float(a[2])) * o;
        high[i] = (r * 0.299f + g * 0.587f + bl * 0.114f) / 255.0f;
        if (b[3] == 0 && a[3] > 0) {
            sum += decoded(float(a[0]) / 255.0f) * 0.299 + decoded(float(a[1]) / 255.0f) * 0.587 +
                decoded(float(a[2]) / 255.0f) * 0.114;
            weight++;
        }
        uint8_t* out = &skin.grain[size_t(flipped(i, size)) * 4];
        out[0] = uint8_t(r);
        out[1] = uint8_t(g);
        out[2] = uint8_t(bl);
        out[3] = b[3] > 0 ? uint8_t(255.0f * (1 - o)) : a[3];
    }
    // Brought to a mean of mid grey in linear light, or a dark tile darkens everything painted with it.
    float gain = weight ? float(std::min(2.0, std::max(0.5, 0.2158605 / (sum / weight)))) : 1.0f;
    for (int i = 0; i < size * size; i++) {
        if (second[size_t(i) * 4 + 3] != 0) { continue; }
        const uint8_t* a = &first[size_t(i) * 4];
        uint8_t* out = &skin.grain[size_t(flipped(i, size)) * 4];
        out[0] = encode8(decoded(float(a[0]) / 255.0f) * gain);
        out[1] = encode8(decoded(float(a[1]) / 255.0f) * gain);
        out[2] = encode8(decoded(float(a[2]) / 255.0f) * gain);
    }
    if (!bumped(finish)) { return skin; }
    skin.relief.assign(size_t(size) * size * 4, 255);
    if (dug && !dug->empty()) {
        Canvas lie(size);
        lie.picture(dug->rgba.data(), dug->wide, dug->tall);
        for (int i = 0; i < size * size; i++) {
            uint8_t n[4];
            lie.read(i, n);
            uint8_t* out = &skin.relief[size_t(flipped(i, size)) * 4];
            out[0] = n[0];
            out[1] = n[1];
            out[2] = n[2];
            out[3] = 255;
        }
    } else {
        slope(high, size, skin.relief);
    }
    return skin;
}

} // namespace hive
