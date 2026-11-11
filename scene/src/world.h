// A scene, drawn: frames in as the bytes uiSceneFrame wrote, pictures out from any eye.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace filament {
class Engine;
class Renderer;
class SwapChain;
} // namespace filament

namespace hive {

// Asked of whoever runs the world; each is answered later through the World, or never.
struct Host {
    virtual ~Host() {}
    virtual void wantPicture(const std::string& path) = 0;
    virtual void wantFile(const std::string& path) = 0;
    virtual void wantTerrain(const std::string& id) = 0;
    virtual void wantLabel(const std::string& words, const std::string& colour) = 0;
};

struct Eye {
    float eye[3] = {0, 0, 0};
    float aim[2] = {0, 0};
    int lens = 0, fog = 0, grain = 0, bits = 0;
    std::string sky;
    bool grab = false, flat = false;
    float sun[2] = {0, -100};
    int shade = 0;
    std::string on;
};

struct Heard {
    float p[3] = {0, 0, 0};
    std::string name, voice, track;
    float pitch = 1, volume = 1;
    uint32_t carry = 0;
};

// An inset's box on the picture, in the sheet's pixels from its top left.
struct Box {
    int left = 0, top = 0, wide = 0, tall = 0;
};

class World {
public:
    World(filament::Engine& engine, Host& host);
    ~World();

    // One frame without its leading 'S'; false means ask for a whole one and draw nothing.
    bool frame(const uint8_t* data, size_t size);

    // How big the picture is shown, then how big it is drawn.
    void sized(int sheetWide, int sheetTall, int drawnWide, int drawnTall);
    void insetsAt(const std::vector<Box>& boxes);

    // Before beginFrame, which is when Filament takes what a material was told: a
    // window reading the picture back wants red and blue traded.
    void ready(bool upsideDown, bool traded);
    // Between beginFrame and endFrame.
    void draw(filament::Renderer& renderer);

    void picture(const std::string& path, int wide, int tall, const uint8_t* rgba);
    void file(const std::string& path, const uint8_t* data, size_t size, bool found);
    void terrain(const std::string& id, const uint8_t* data, size_t size);
    void label(const std::string& words, const std::string& colour, int wide, int tall, const uint8_t* rgba);

    bool stale() const;
    const Eye& eye() const;
    const std::vector<const Heard*>& sounds();

private:
    struct Inner;
    std::unique_ptr<Inner> in;
};

} // namespace hive
