// Every solid of a kind is one unit geometry; its size is in its matrix.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace hive {

struct Mesh {
    std::vector<float> place;    // x y z
    std::vector<float> facing;   // x y z
    std::vector<float> uv;       // u v
    std::vector<float> spanU;    // x y z
    std::vector<float> spanV;    // x y z
    std::vector<float> rounding; // 0 none, 1 a box's corner, 2 a drum's side, 3 a drum's end
    std::vector<float> along;    // x y z w: the way u runs, and which hand v is on
    std::vector<uint32_t> index;

    size_t count() const { return place.size() / 3; }
};

// "box", "sphere", "cylinder", "roof", "ground", or "cone|top|bottom" in thirty-seconds of the wider end.
Mesh unitMesh(const std::string& form);

void directions(Mesh& mesh);

} // namespace hive
