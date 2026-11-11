// What a world sounds like: each frame's sounds against the voices already going.
#pragma once

#include "world.h"

#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace hive {

class Sound {
public:
    // `want` asks for a recording under assets/, answered with file().
    explicit Sound(std::function<void(const std::string&)> want);
    ~Sound();

    void hear(const std::vector<const Heard*>& sounds, const Eye& eye);
    // False where the file is not one this asked for.
    bool file(const std::string& path, const uint8_t* data, size_t size, bool found);
    void loud(float volume);

    // A stream by name, as hive.audio plays one: opened, fed its bytes as they
    // arrive — none at all says no more are coming — turned up or down, and shut.
    void open(const std::string& name, float volume);
    void feed(const std::string& name, const uint8_t* data, size_t size);
    void turn(const std::string& name, float volume);
    void shut(const std::string& name);
    // The streams that have played all they were fed, each named once.
    std::vector<std::string> spent();

private:
    struct Inner;
    std::unique_ptr<Inner> in;
};

} // namespace hive
