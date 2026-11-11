// A finish's two squares of pixels, grain and relief, drawn here unless the program shipped a photograph.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace hive {

struct Picture {
    int wide = 0, tall = 0;
    std::vector<uint8_t> rgba;
    bool empty() const { return rgba.empty(); }
};

struct Skin {
    int size = 0;
    std::vector<uint8_t> grain;  // rgba, rows counted up
    std::vector<uint8_t> relief; // rgba, rows counted up; empty where a finish has none
};

struct Look {
    float rough, metal, relief;
};

Look lookOf(const std::string& finish);
bool bumped(const std::string& finish);
bool broad(const std::string& finish);
float perTile(const std::string& finish);

Skin weave(const std::string& finish, const Picture* shot, const Picture* dug);

} // namespace hive
