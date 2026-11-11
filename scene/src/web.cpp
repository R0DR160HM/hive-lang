// The engine a page draws a scene with: the same world, on the page's own canvas.
#include "world.h"

#include <filament/Engine.h>
#include <filament/Renderer.h>
#include <filament/SwapChain.h>

#include <emscripten.h>
#include <emscripten/html5.h>

#include <cstdio>
#include <string>
#include <vector>

using namespace filament;

namespace {

EM_JS(void, wanted, (int kind, const char* first, const char* second), {
    Module.wanted(kind, UTF8ToString(first), UTF8ToString(second));
});

struct Asking : public hive::Host {
    void wantPicture(const std::string& path) override { wanted(0, path.c_str(), ""); }
    void wantFile(const std::string& path) override { wanted(1, path.c_str(), ""); }
    void wantTerrain(const std::string& id) override { wanted(2, id.c_str(), ""); }
    void wantLabel(const std::string& words, const std::string& colour) override {
        wanted(3, words.c_str(), colour.c_str());
    }
};

Engine* engine = nullptr;
Renderer* renderer = nullptr;
SwapChain* chain = nullptr;
hive::World* world = nullptr;
Asking asking;
std::string told;

void quoted(std::string& out, const std::string& text) {
    out.push_back('"');
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') {
            out.push_back('\\');
            out.push_back(char(c));
        } else if (c < 0x20) {
            char code[8];
            snprintf(code, sizeof code, "\\u%04x", c);
            out += code;
        } else {
            out.push_back(char(c));
        }
    }
    out.push_back('"');
}

void number(std::string& out, float v) {
    char text[32];
    snprintf(text, sizeof text, "%.6g", double(v == v ? v : 0));
    out += text;
}

} // namespace

extern "C" {

EMSCRIPTEN_KEEPALIVE int hs_start(const char* canvas) {
    EmscriptenWebGLContextAttributes with;
    emscripten_webgl_init_context_attributes(&with);
    with.majorVersion = 2;
    with.minorVersion = 0;
    with.alpha = false;
    with.depth = true;
    with.stencil = false;
    with.antialias = false;
    with.powerPreference = EM_WEBGL_POWER_PREFERENCE_HIGH_PERFORMANCE;
    EMSCRIPTEN_WEBGL_CONTEXT_HANDLE context = emscripten_webgl_create_context(canvas, &with);
    if (context <= 0) { return 0; }
    emscripten_webgl_make_context_current(context);
    engine = Engine::Builder().backend(Engine::Backend::OPENGL).build();
    if (!engine) { return 0; }
    renderer = engine->createRenderer();
    Renderer::ClearOptions wipe;
    wipe.clearColor = {0, 0, 0, 1};
    wipe.clear = true;
    renderer->setClearOptions(wipe);
    chain = engine->createSwapChain(nullptr);
    world = new hive::World(*engine, asking);
    engine->execute();
    return 1;
}

// 1 where the frame was taken, 0 where it was cut from one this world never held.
EMSCRIPTEN_KEEPALIVE int hs_frame(const uint8_t* data, int size) {
    if (!world || size < 1) { return 1; }
    return world->frame(data + 1, size_t(size - 1)) ? 1 : 0;
}

// What the page has to know of the frame that is not drawn: who is listening for what, and every sound.
EMSCRIPTEN_KEEPALIVE const char* hs_told() {
    told.clear();
    if (!world) { return "{}"; }
    const hive::Eye& eye = world->eye();
    told += "{\"on\":";
    quoted(told, eye.on);
    told += eye.grab ? ",\"grab\":true" : ",\"grab\":false";
    told += ",\"eye\":[";
    number(told, eye.eye[0]);
    told += ",";
    number(told, eye.eye[1]);
    told += ",";
    number(told, eye.eye[2]);
    told += "],\"aim\":[";
    number(told, eye.aim[0]);
    told += ",";
    number(told, eye.aim[1]);
    told += "],\"sounds\":[";
    bool first = true;
    for (const hive::Heard* s : world->sounds()) {
        if (!first) { told += ","; }
        first = false;
        told += "{\"x\":";
        quoted(told, s->name);
        told += ",\"v\":";
        quoted(told, s->voice);
        told += ",\"t\":";
        quoted(told, s->track);
        told += ",\"p\":[";
        number(told, s->p[0]);
        told += ",";
        number(told, s->p[1]);
        told += ",";
        number(told, s->p[2]);
        told += "],\"g\":";
        number(told, s->volume);
        told += ",\"h\":";
        number(told, s->pitch);
        told += "}";
    }
    told += "]}";
    return told.c_str();
}

EMSCRIPTEN_KEEPALIVE void hs_sized(int sheetWide, int sheetTall, int drawnWide, int drawnTall) {
    if (world) { world->sized(sheetWide, sheetTall, drawnWide, drawnTall); }
}

EMSCRIPTEN_KEEPALIVE void hs_insets(const int32_t* at, int many) {
    if (!world) { return; }
    std::vector<hive::Box> boxes(size_t(many < 0 ? 0 : many));
    for (size_t i = 0; i < boxes.size(); i++) {
        boxes[i].left = at[i * 4];
        boxes[i].top = at[i * 4 + 1];
        boxes[i].wide = at[i * 4 + 2];
        boxes[i].tall = at[i * 4 + 3];
    }
    world->insetsAt(boxes);
}

EMSCRIPTEN_KEEPALIVE void hs_draw() {
    if (!world) { return; }
    world->ready(false, false);
    if (renderer->beginFrame(chain)) {
        world->draw(*renderer);
        renderer->endFrame();
    }
    engine->execute();
}

EMSCRIPTEN_KEEPALIVE int hs_stale() { return world && world->stale() ? 1 : 0; }

EMSCRIPTEN_KEEPALIVE void hs_picture(const char* path, int wide, int tall, const uint8_t* rgba) {
    if (world) { world->picture(path, wide, tall, rgba); }
}

EMSCRIPTEN_KEEPALIVE void hs_file(const char* path, const uint8_t* data, int size, int found) {
    if (world) { world->file(path, data, size_t(size), found != 0); }
}

EMSCRIPTEN_KEEPALIVE void hs_terrain(const char* id, const uint8_t* data, int size) {
    if (world) { world->terrain(id, data, size_t(size)); }
}

EMSCRIPTEN_KEEPALIVE void hs_label(const char* words, const char* colour, int wide, int tall, const uint8_t* rgba) {
    if (world) { world->label(words, colour, wide, tall, rgba); }
}

} // extern "C"
