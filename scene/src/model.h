// A glTF binary, read into what a figure needs, one part a primitive: skinned, or each mesh on a joint of its own.
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

// One part of a joint moving through a clip: where it stands, how it is turned or how big it is.
struct Track {
    int joint = -1;
    int path = 0; // 0 where it stands, 1 how it is turned, 2 how big it is
    int how = 0;  // 0 straight between keys, 1 a key at a time, 2 along a curve
    std::vector<float> times, values;
};

struct Clip {
    std::string name;
    float length = 0;
    std::vector<Track> tracks;
    // A joint's place, turn and size at a moment, wherever the clip moves it.
    void pose(int joint, float at, float t[3], float r[4], float s[3]) const;
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
    std::vector<Clip> clips;
    // A clip by its name, or by its place in the file where it has none; nothing for "".
    const Clip* clipNamed(const std::string& name) const;
};

// Answers false for a file that is not a glTF binary with a mesh in it.
bool readModel(Model& into, const uint8_t* data, size_t size);

} // namespace hive
