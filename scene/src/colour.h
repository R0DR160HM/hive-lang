// A colour as a scene says it: CSS, with the alpha inside it.
#pragma once

#include <cmath>
#include <cstdlib>
#include <string>

namespace hive {

struct Colour {
    float r = 1, g = 1, b = 1; // linear
    float a = 1;
    unsigned char sr = 255, sg = 255, sb = 255; // as written
};

inline float decoded(float v) {
    return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
}

inline float encoded(float v) {
    v = v < 0 ? 0 : (v > 1 ? 1 : v);
    return v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1 / 2.4f) - 0.055f;
}

inline int hexDigit(char c) {
    if (c >= '0' && c <= '9') { return c - '0'; }
    if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
    if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
    return -1;
}

// Anything unreadable is opaque white.
inline Colour colourOf(const std::string& s) {
    Colour c;
    int r = 255, g = 255, b = 255;
    float a = 1;
    if (s.size() > 5 && s.compare(0, 5, "rgba(") == 0) {
        const char* p = s.c_str() + 5;
        char* end = nullptr;
        r = int(strtol(p, &end, 10));
        if (*end == ',') { end++; }
        g = int(strtol(end, &end, 10));
        if (*end == ',') { end++; }
        b = int(strtol(end, &end, 10));
        if (*end == ',') {
            end++;
            a = strtof(end, &end);
        }
    } else if (!s.empty() && s[0] == '#') {
        size_t n = s.size() - 1;
        int d[8] = {0, 0, 0, 0, 0, 0, 0, 0};
        bool ok = n == 3 || n == 4 || n == 6 || n == 8;
        for (size_t i = 0; ok && i < n; i++) {
            d[i] = hexDigit(s[i + 1]);
            if (d[i] < 0) { ok = false; }
        }
        if (ok && n <= 4) {
            r = d[0] * 17;
            g = d[1] * 17;
            b = d[2] * 17;
            if (n == 4) { a = float(d[3]) / 15.0f; }
        } else if (ok) {
            r = d[0] * 16 + d[1];
            g = d[2] * 16 + d[3];
            b = d[4] * 16 + d[5];
            if (n == 8) { a = float(d[6] * 16 + d[7]) / 255.0f; }
        }
    }
    auto channel = [](int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); };
    r = channel(r);
    g = channel(g);
    b = channel(b);
    if (!(a >= 0 && a <= 1)) { a = 1; }
    c.sr = (unsigned char) r;
    c.sg = (unsigned char) g;
    c.sb = (unsigned char) b;
    c.r = decoded(float(r) / 255.0f);
    c.g = decoded(float(g) / 255.0f);
    c.b = decoded(float(b) / 255.0f);
    c.a = a;
    return c;
}

inline float luma(float r, float g, float b) {
    return 0.2126f * r + 0.7152f * g + 0.0722f * b;
}

} // namespace hive
