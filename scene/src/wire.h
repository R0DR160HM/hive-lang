// A frame, read in the order uiSceneFrame writes it; a read past the end answers nought.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>

namespace hive {

struct Reader {
    const uint8_t* data = nullptr;
    size_t size = 0;
    size_t at = 0;
    bool short_ = false;

    Reader(const uint8_t* d, size_t n) : data(d), size(n) {}

    bool has(size_t n) {
        if (at + n > size) {
            short_ = true;
            return false;
        }
        return true;
    }

    uint8_t u8() {
        if (!has(1)) { return 0; }
        return data[at++];
    }

    uint16_t u16() {
        if (!has(2)) { return 0; }
        uint16_t v = uint16_t(data[at]) | uint16_t(data[at + 1]) << 8;
        at += 2;
        return v;
    }

    uint32_t u32() {
        if (!has(4)) { return 0; }
        uint32_t v = uint32_t(data[at]) | uint32_t(data[at + 1]) << 8 | uint32_t(data[at + 2]) << 16 |
            uint32_t(data[at + 3]) << 24;
        at += 4;
        return v;
    }

    float f32() {
        uint32_t bits = u32();
        float v;
        memcpy(&v, &bits, 4);
        return v;
    }

    std::string text(size_t n) {
        if (!has(n)) { return std::string(); }
        std::string s(reinterpret_cast<const char*>(data + at), n);
        at += n;
        return s;
    }

    std::string word() { return text(u8()); }
    std::string longText() { return text(u16()); }
};

} // namespace hive
