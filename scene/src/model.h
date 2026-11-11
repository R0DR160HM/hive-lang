// A skinned glTF binary, read into what a figure needs, one part a primitive.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace hive {

const int PARTS = 32;

struct Joint {
    int parent = -1;
    float t[3] = {0, 0, 0};
    float r[4] = {0, 0, 0, 1}; // x y z w
    float s[3] = {1, 1, 1};
};

struct Model {
    bool ready = false;
    std::vector<float> place;   // x y z
    std::vector<float> facing;  // x y z
    std::vector<uint8_t> tint;  // r g b, linear, a channel each
    std::vector<float> bones;   // four a vertex
    std::vector<float> weights; // four a vertex
    std::vector<uint8_t> part;  // one a vertex
    std::vector<uint32_t> index;
    std::vector<Joint> joints;
    std::vector<float> inverses; // sixteen a joint, column by column
    std::vector<int> order;      // parents before their children
    float tints[PARTS * 4];      // the file's own colour for each part
};

// Answers false for a file that is not a skinned glTF binary.
bool readModel(Model& into, const uint8_t* data, size_t size);

} // namespace hive
