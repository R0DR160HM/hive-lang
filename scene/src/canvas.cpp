#include "canvas.h"

#include <algorithm>
#include <cmath>

namespace hive {

namespace {

const int ROWS = 8; // how many lines a pixel's height is read on

struct Crossing {
    float x;
    int way;
};

} // namespace

Canvas::Canvas(int size) : side(size), px(size_t(size) * size * 4, 0), wet(size_t(size) * size, 0) {}

void Canvas::clear() { std::fill(px.begin(), px.end(), 0.0f); }

void Canvas::flood(Ink c) {
    for (int i = 0; i < side * side; i++) {
        px[i * 4] = c.r * c.a;
        px[i * 4 + 1] = c.g * c.a;
        px[i * 4 + 2] = c.b * c.a;
        px[i * 4 + 3] = c.a;
    }
}

void Canvas::lay(int x, int y, Ink c, float cover) {
    float a = c.a * cover;
    if (a <= 0) { return; }
    float* p = &px[(size_t(y) * side + x) * 4];
    p[0] = c.r * a + p[0] * (1 - a);
    p[1] = c.g * a + p[1] * (1 - a);
    p[2] = c.b * a + p[2] * (1 - a);
    p[3] = a + p[3] * (1 - a);
}

void Canvas::shapes(const std::vector<std::vector<float>>& outlines, Ink c) {
    float top = 1e9f, low = -1e9f, left = 1e9f, right = -1e9f;
    for (const auto& o : outlines) {
        for (size_t i = 0; i + 1 < o.size(); i += 2) {
            left = std::min(left, o[i] * scale);
            right = std::max(right, o[i] * scale);
            top = std::min(top, o[i + 1] * scale);
            low = std::max(low, o[i + 1] * scale);
        }
    }
    int y0 = std::max(0, int(std::floor(top))), y1 = std::min(side, int(std::ceil(low)));
    int x0 = std::max(0, int(std::floor(left))), x1 = std::min(side, int(std::ceil(right)));
    if (y0 >= y1 || x0 >= x1) { return; }
    std::vector<Crossing> hits;
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) { wet[size_t(y) * side + x] = 0; }
        for (int s = 0; s < ROWS; s++) {
            float line = float(y) + (float(s) + 0.5f) / float(ROWS);
            hits.clear();
            for (const auto& o : outlines) {
                size_t n = o.size() / 2;
                for (size_t i = 0; i < n; i++) {
                    float ax = o[i * 2] * scale, ay = o[i * 2 + 1] * scale;
                    size_t j = (i + 1) % n;
                    float bx = o[j * 2] * scale, by = o[j * 2 + 1] * scale;
                    if ((ay <= line && by > line) || (by <= line && ay > line)) {
                        hits.push_back(Crossing{ax + (line - ay) / (by - ay) * (bx - ax), by > ay ? 1 : -1});
                    }
                }
            }
            std::sort(hits.begin(), hits.end(), [](const Crossing& a, const Crossing& b) { return a.x < b.x; });
            int inside = 0;
            for (size_t h = 0; h + 1 < hits.size(); h++) {
                inside += hits[h].way;
                if (inside == 0) { continue; }
                float from = std::max(hits[h].x, float(x0)), to = std::min(hits[h + 1].x, float(x1));
                if (to <= from) { continue; }
                int first = int(std::floor(from)), last = std::min(x1 - 1, int(std::floor(to)));
                for (int x = first; x <= last; x++) {
                    float part = std::min(to, float(x + 1)) - std::max(from, float(x));
                    if (part > 0) { wet[size_t(y) * side + x] += part / float(ROWS); }
                }
            }
        }
        for (int x = x0; x < x1; x++) {
            float cover = wet[size_t(y) * side + x];
            if (cover > 0) { lay(x, y, c, std::min(1.0f, cover)); }
        }
    }
}

void Canvas::rect(float x, float y, float w, float h, Ink c) {
    shapes({{x, y, x + w, y, x + w, y + h, x, y + h}}, c);
}

void Canvas::erase(float x, float y, float w, float h) {
    int x0 = std::max(0, int(std::floor(x * scale))), x1 = std::min(side, int(std::ceil((x + w) * scale)));
    int y0 = std::max(0, int(std::floor(y * scale))), y1 = std::min(side, int(std::ceil((y + h) * scale)));
    for (int py = y0; py < y1; py++) {
        for (int qx = x0; qx < x1; qx++) {
            float* p = &px[(size_t(py) * side + qx) * 4];
            p[0] = p[1] = p[2] = p[3] = 0;
        }
    }
}

void Canvas::frame(float x, float y, float w, float h, float thick, Ink c) {
    float t = thick / 2;
    shapes({{x - t, y - t, x + w + t, y - t, x + w + t, y + h + t, x - t, y + h + t},
        {x + t, y + t, x + t, y + h - t, x + w - t, y + h - t, x + w - t, y + t}}, c);
}

void Canvas::disc(float cx, float cy, float r, Ink c) {
    std::vector<float> o;
    int n = r * scale > 3 ? 24 : 14;
    for (int i = 0; i < n; i++) {
        float t = float(i) / float(n) * 6.2831853f;
        o.push_back(cx + std::cos(t) * r);
        o.push_back(cy + std::sin(t) * r);
    }
    shapes({o}, c);
}

void Canvas::oval(float cx, float cy, float rx, float ry, float turn, Ink c) {
    std::vector<float> o;
    float sn = std::sin(turn), cs = std::cos(turn);
    for (int i = 0; i < 18; i++) {
        float t = float(i) / 18.0f * 6.2831853f;
        float x = std::cos(t) * rx, y = std::sin(t) * ry;
        o.push_back(cx + x * cs - y * sn);
        o.push_back(cy + x * sn + y * cs);
    }
    shapes({o}, c);
}

// One outline, out one side and back the other, so a see-through stroke is not laid twice at a bend.
void Canvas::stroke(const std::vector<float>& points, float thick, Ink c) {
    size_t n = points.size() / 2;
    if (n < 2) { return; }
    std::vector<float> near(n * 2), far(n * 2);
    for (size_t i = 0; i < n; i++) {
        size_t a = i == 0 ? 0 : i - 1, b = i + 1 < n ? i + 1 : i;
        float dx = points[b * 2] - points[a * 2], dy = points[b * 2 + 1] - points[a * 2 + 1];
        float len = std::sqrt(dx * dx + dy * dy);
        if (len < 1e-6f) {
            dx = 1;
            dy = 0;
            len = 1;
        }
        float nx = -dy / len * thick / 2, ny = dx / len * thick / 2;
        near[i * 2] = points[i * 2] + nx;
        near[i * 2 + 1] = points[i * 2 + 1] + ny;
        far[i * 2] = points[i * 2] - nx;
        far[i * 2 + 1] = points[i * 2 + 1] - ny;
    }
    std::vector<float> o(near);
    for (size_t i = n; i > 0; i--) {
        o.push_back(far[(i - 1) * 2]);
        o.push_back(far[(i - 1) * 2 + 1]);
    }
    shapes({o}, c);
}

void Canvas::curve(float x0, float y0, float c1x, float c1y, float c2x, float c2y, float x1, float y1, float thick,
        Ink c) {
    std::vector<float> points;
    for (int i = 0; i <= 16; i++) {
        float t = float(i) / 16.0f, u = 1 - t;
        float a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t;
        points.push_back(a * x0 + b * c1x + d * c2x + e * x1);
        points.push_back(a * y0 + b * c1y + d * c2y + e * y1);
    }
    stroke(points, thick, c);
}

void Canvas::shaded(float x, float y, float w, float h, const std::vector<float>& at, const std::vector<Ink>& tones) {
    float top = y * scale, low = (y + h) * scale, left = x * scale, right = (x + w) * scale;
    int y0 = std::max(0, int(std::floor(top))), y1 = std::min(side, int(std::ceil(low)));
    int x0 = std::max(0, int(std::floor(left))), x1 = std::min(side, int(std::ceil(right)));
    for (int py = y0; py < y1; py++) {
        float tall = std::min(low, float(py + 1)) - std::max(top, float(py));
        if (tall <= 0) { continue; }
        float t = (float(py) + 0.5f - top) / std::max(1e-6f, low - top);
        t = std::min(1.0f, std::max(0.0f, t));
        Ink c = tones.back();
        for (size_t k = 0; k + 1 < at.size(); k++) {
            if (t <= at[k + 1]) {
                float f = (t - at[k]) / std::max(1e-6f, at[k + 1] - at[k]);
                f = std::min(1.0f, std::max(0.0f, f));
                c = Ink{tones[k].r + (tones[k + 1].r - tones[k].r) * f, tones[k].g + (tones[k + 1].g - tones[k].g) * f,
                    tones[k].b + (tones[k + 1].b - tones[k].b) * f, tones[k].a + (tones[k + 1].a - tones[k].a) * f};
                break;
            }
        }
        for (int qx = x0; qx < x1; qx++) {
            float wide = std::min(right, float(qx + 1)) - std::max(left, float(qx));
            if (wide > 0) { lay(qx, py, c, tall * wide); }
        }
    }
}

void Canvas::picture(const uint8_t* rgba, int w, int h) {
    if (w <= 0 || h <= 0) { return; }
    for (int y = 0; y < side; y++) {
        for (int x = 0; x < side; x++) {
            float sum[4] = {0, 0, 0, 0}, weight = 0;
            float fx0 = float(x) * float(w) / float(side), fx1 = float(x + 1) * float(w) / float(side);
            float fy0 = float(y) * float(h) / float(side), fy1 = float(y + 1) * float(h) / float(side);
            if (w >= side && h >= side) {
                for (int sy = int(fy0); sy < std::min(h, int(std::ceil(fy1))); sy++) {
                    for (int sx = int(fx0); sx < std::min(w, int(std::ceil(fx1))); sx++) {
                        const uint8_t* s = rgba + (size_t(sy) * w + sx) * 4;
                        float a = float(s[3]) / 255.0f;
                        sum[0] += float(s[0]) / 255.0f * a;
                        sum[1] += float(s[1]) / 255.0f * a;
                        sum[2] += float(s[2]) / 255.0f * a;
                        sum[3] += a;
                        weight += 1;
                    }
                }
            } else {
                float cx = (fx0 + fx1) / 2 - 0.5f, cy = (fy0 + fy1) / 2 - 0.5f;
                int ix = int(std::floor(cx)), iy = int(std::floor(cy));
                float tx = cx - float(ix), ty = cy - float(iy);
                for (int k = 0; k < 4; k++) {
                    int sx = std::min(w - 1, std::max(0, ix + (k & 1))), sy = std::min(h - 1, std::max(0, iy + (k >> 1)));
                    float part = ((k & 1) ? tx : 1 - tx) * ((k >> 1) ? ty : 1 - ty);
                    const uint8_t* s = rgba + (size_t(sy) * w + sx) * 4;
                    float a = float(s[3]) / 255.0f;
                    sum[0] += float(s[0]) / 255.0f * a * part;
                    sum[1] += float(s[1]) / 255.0f * a * part;
                    sum[2] += float(s[2]) / 255.0f * a * part;
                    sum[3] += a * part;
                    weight += part;
                }
            }
            float* p = &px[(size_t(y) * side + x) * 4];
            if (weight <= 0) { continue; }
            float a = sum[3] / weight;
            p[0] = sum[0] / weight + p[0] * (1 - a);
            p[1] = sum[1] / weight + p[1] * (1 - a);
            p[2] = sum[2] / weight + p[2] * (1 - a);
            p[3] = a + p[3] * (1 - a);
        }
    }
}

void Canvas::read(int i, uint8_t out[4]) const {
    const float* p = &px[size_t(i) * 4];
    float a = p[3];
    if (a <= 0) {
        out[0] = out[1] = out[2] = out[3] = 0;
        return;
    }
    for (int k = 0; k < 3; k++) {
        float v = p[k] / a * 255.0f;
        out[k] = uint8_t(std::min(255.0f, std::max(0.0f, std::round(v))));
    }
    out[3] = uint8_t(std::min(255.0f, std::max(0.0f, std::round(a * 255.0f))));
}

void Canvas::write(int i, const uint8_t in[4]) {
    float* p = &px[size_t(i) * 4];
    float a = float(in[3]) / 255.0f;
    p[0] = float(in[0]) / 255.0f * a;
    p[1] = float(in[1]) / 255.0f * a;
    p[2] = float(in[2]) / 255.0f * a;
    p[3] = a;
}

} // namespace hive
