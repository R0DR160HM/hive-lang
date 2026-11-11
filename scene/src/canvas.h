// The part of a page's 2D canvas the surface drawings use.
#pragma once

#include <cstdint>
#include <vector>

namespace hive {

struct Ink {
    float r = 0, g = 0, b = 0, a = 1; // 0..1, as written (not yet multiplied through)
};

inline Ink ink(float r, float g, float b, float a = 1) { return Ink{r / 255.0f, g / 255.0f, b / 255.0f, a}; }
inline Ink black(float a) { return Ink{0, 0, 0, a}; }
inline Ink white(float a) { return Ink{1, 1, 1, a}; }

class Canvas {
public:
    explicit Canvas(int size);

    int size() const { return side; }
    void scaled(float by) { scale = by; }

    void clear();
    void flood(Ink c);
    void rect(float x, float y, float w, float h, Ink c);
    void erase(float x, float y, float w, float h);
    void frame(float x, float y, float w, float h, float thick, Ink c);
    void shapes(const std::vector<std::vector<float>>& outlines, Ink c);
    void disc(float cx, float cy, float r, Ink c);
    void oval(float cx, float cy, float rx, float ry, float turn, Ink c);
    void stroke(const std::vector<float>& points, float thick, Ink c);
    void curve(float x0, float y0, float c1x, float c1y, float c2x, float c2y, float x1, float y1, float thick, Ink c);
    void shaded(float x, float y, float w, float h, const std::vector<float>& at, const std::vector<Ink>& tones);
    void picture(const uint8_t* rgba, int w, int h);

    void read(int i, uint8_t out[4]) const;
    void write(int i, const uint8_t in[4]);

private:
    void lay(int x, int y, Ink c, float cover);

    int side;
    float scale = 1;
    std::vector<float> px;  // multiplied through
    std::vector<float> wet; // how much of each pixel the shape being filled covers
};

} // namespace hive
