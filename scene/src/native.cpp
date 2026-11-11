// The engine a window starts beside itself; scene/README.md has the messages.
#include "sound.h"
#include "world.h"

#include <backend/PixelBufferDescriptor.h>
#include <filament/Engine.h>
#include <filament/Renderer.h>
#include <filament/SwapChain.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

using namespace filament;

#if defined(__linux__)
// The prebuilt backend names this for a WebGPU surface nothing here makes.
extern "C" int XGetWindowAttributes(void*, unsigned long, void*) { return 0; }
#endif

namespace {

FILE* said = nullptr;
FILE* told = nullptr;
FILE* kept = nullptr;

void put32(std::string& out, uint32_t v) {
    out.push_back(char(v));
    out.push_back(char(v >> 8));
    out.push_back(char(v >> 16));
    out.push_back(char(v >> 24));
}

void put16(std::string& out, size_t v) {
    out.push_back(char(v));
    out.push_back(char(v >> 8));
}

std::mutex saying;

void say(char kind, const std::string& body) {
    if (!said) { return; }
    std::lock_guard<std::mutex> held(saying);
    std::string head(1, kind);
    put32(head, uint32_t(body.size()));
    fwrite(head.data(), 1, head.size(), said);
    fwrite(body.data(), 1, body.size(), said);
    fflush(said);
}

bool heard(char& kind, std::vector<uint8_t>& body) {
    uint8_t head[5];
    if (fread(head, 1, 5, told) != 5) { return false; }
    kind = char(head[0]);
    uint32_t size = uint32_t(head[1]) | uint32_t(head[2]) << 8 | uint32_t(head[3]) << 16 | uint32_t(head[4]) << 24;
    if (size > (1u << 30)) { return false; }
    body.resize(size);
    if (size != 0 && fread(body.data(), 1, size, told) != size) { return false; }
    if (kept) {
        fwrite(head, 1, 5, kept);
        fwrite(body.data(), 1, size, kept);
        fflush(kept);
    }
    return true;
}

struct Asking : public hive::Host {
    void wantPicture(const std::string& path) override { say('p', path); }
    void wantFile(const std::string& path) override { say('f', path); }
    void wantTerrain(const std::string& id) override { say('t', id); }
    void wantLabel(const std::string& words, const std::string& colour) override {
        std::string body;
        put16(body, words.size());
        body += words;
        body += colour;
        say('l', body);
    }
};

struct Held {
    uint8_t* at = nullptr;
    size_t size = 0;
    std::vector<uint8_t> own;
#ifdef _WIN32
    HANDLE mapping = nullptr;
#endif

    void drop() {
        if (!at || !own.empty()) {
            own.clear();
            at = nullptr;
            return;
        }
#ifdef _WIN32
        UnmapViewOfFile(at);
        CloseHandle(mapping);
        mapping = nullptr;
#else
        munmap(at, size);
#endif
        at = nullptr;
        size = 0;
    }

    void alone(size_t bytes) {
        drop();
        own.assign(bytes, 0);
        at = own.data();
        size = bytes;
    }

    bool take(const std::string& name, size_t bytes) {
        drop();
#ifdef _WIN32
        int wide = MultiByteToWideChar(CP_UTF8, 0, name.c_str(), -1, nullptr, 0);
        std::wstring w(size_t(wide), 0);
        MultiByteToWideChar(CP_UTF8, 0, name.c_str(), -1, &w[0], wide);
        mapping = OpenFileMappingW(FILE_MAP_WRITE, FALSE, w.c_str());
        if (!mapping) { return false; }
        at = static_cast<uint8_t*>(MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, bytes));
        if (!at) {
            CloseHandle(mapping);
            mapping = nullptr;
            return false;
        }
#else
        int fd = open(name.c_str(), O_RDWR);
        if (fd < 0) { return false; }
        void* got = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (got == MAP_FAILED) { return false; }
        at = static_cast<uint8_t*>(got);
#endif
        size = bytes;
        return true;
    }
};

struct Reading {
    const std::vector<uint8_t>& b;
    size_t at = 0;
    explicit Reading(const std::vector<uint8_t>& body) : b(body) {}
    uint32_t u32() {
        if (at + 4 > b.size()) {
            at = b.size();
            return 0;
        }
        uint32_t v = uint32_t(b[at]) | uint32_t(b[at + 1]) << 8 | uint32_t(b[at + 2]) << 16 | uint32_t(b[at + 3]) << 24;
        at += 4;
        return v;
    }
    std::string text(size_t n) {
        n = std::min(n, b.size() - at);
        std::string s(reinterpret_cast<const char*>(b.data() + at), n);
        at += n;
        return s;
    }
    std::string named() {
        if (at + 2 > b.size()) { return std::string(); }
        size_t n = size_t(b[at]) | size_t(b[at + 1]) << 8;
        at += 2;
        return text(n);
    }
    const uint8_t* rest() const { return b.data() + at; }
    size_t left() const { return b.size() - at; }
};

struct Seat {
    Engine* engine = nullptr;
    Renderer* renderer = nullptr;
    SwapChain* chain = nullptr;
    int wide = 0, tall = 0;
    Held memory;

    double draw(hive::World& world) {
        auto began = std::chrono::steady_clock::now();
        // Drawn whatever Filament says of its pace: the window asked, and waits for this picture.
        world.ready(false, true);
        renderer->beginFrame(chain);
        world.draw(*renderer);
        renderer->readPixels(0, 0, uint32_t(wide), uint32_t(tall),
            backend::PixelBufferDescriptor(memory.at, memory.size, backend::PixelDataFormat::RGBA,
                backend::PixelDataType::UBYTE));
        renderer->endFrame();
        engine->flushAndWait();
        return std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - began).count();
    }
};

} // namespace

int main(int argc, char** argv) {
    Engine::Backend backend = Engine::Backend::VULKAN;
    const char* replay = nullptr;
    const char* shot = nullptr;
    int times = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--opengl")) { backend = Engine::Backend::OPENGL; }
        if (!strcmp(argv[i], "--replay") && i + 1 < argc) { replay = argv[++i]; }
        if (!strcmp(argv[i], "--shot") && i + 1 < argc) { shot = argv[++i]; }
        if (!strcmp(argv[i], "--times") && i + 1 < argc) { times = atoi(argv[++i]); }
    }
    if (replay) {
        told = fopen(replay, "rb");
        if (!told) {
            fprintf(stderr, "hive-scene: cannot read %s\n", replay);
            return 1;
        }
    } else {
        // Whatever else writes to the standard output must not land among the messages.
#ifdef _WIN32
        _setmode(_fileno(stdin), _O_BINARY);
        int out = _dup(_fileno(stdout));
        _setmode(out, _O_BINARY);
        _dup2(_fileno(stderr), _fileno(stdout));
        said = _fdopen(out, "wb");
#else
        int out = dup(1);
        dup2(2, 1);
        said = fdopen(out, "wb");
#endif
        told = stdin;
        if (const char* record = getenv("HIVE_SCENE_RECORD")) { kept = fopen(record, "wb"); }
    }

    Seat seat;
    seat.engine = Engine::Builder().backend(backend).feature(hive::SHARED_BUFFER, false).build();
    if (!seat.engine) {
        say('X', "nothing here to draw a scene with");
        if (replay) { fprintf(stderr, "hive-scene: nothing here to draw a scene with\n"); }
        return 1;
    }
    seat.renderer = seat.engine->createRenderer();
    Renderer::ClearOptions wipe;
    wipe.clearColor = {0, 0, 0, 1};
    wipe.clear = true;
    seat.renderer->setClearOptions(wipe);
    Asking asking;
    {
        hive::World world(*seat.engine, asking);
        hive::Sound sound([](const std::string& path) { say('f', path); });
        // A stream ends in its own time, and a still scene sends nothing to be woken by.
        std::thread([&sound]() {
            for (;;) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                for (const std::string& name : sound.spent()) { say('a', name); }
            }
        }).detach();
        say('R', "");

        char kind = 0;
        std::vector<uint8_t> body;
        std::vector<double> played;
        while (heard(kind, body)) {
            Reading r(body);
            if (kind == 'Q') { break; }
            switch (kind) {
            case 'S':
                if (!world.frame(body.data(), body.size())) {
                    say('N', "");
                } else if (!replay) {
                    sound.hear(world.sounds(), world.eye());
                }
                break;
            case 'Z': {
                int sheetWide = int(r.u32()), sheetTall = int(r.u32());
                int drawnWide = int(r.u32()), drawnTall = int(r.u32());
                std::string name = r.text(r.left());
                if (sheetWide < 1 || sheetTall < 1 || sheetWide > 16384 || sheetTall > 16384) { break; }
                size_t bytes = size_t(sheetWide) * size_t(sheetTall) * 4;
                if (replay) { seat.memory.alone(bytes); }
                else if (!seat.memory.take(name, bytes)) { break; }
                if (sheetWide != seat.wide || sheetTall != seat.tall) {
                    if (seat.chain) { seat.engine->destroy(seat.chain); }
                    seat.chain = seat.engine->createSwapChain(uint32_t(sheetWide), uint32_t(sheetTall), 0);
                    seat.wide = sheetWide;
                    seat.tall = sheetTall;
                }
                world.sized(sheetWide, sheetTall, drawnWide, drawnTall);
                break;
            }
            case 'I': {
                std::vector<hive::Box> boxes(body.empty() ? 0 : size_t(body[0]));
                r.at = 1;
                for (auto& box : boxes) {
                    box.left = int(r.u32());
                    box.top = int(r.u32());
                    box.wide = int(r.u32());
                    box.tall = int(r.u32());
                }
                world.insetsAt(boxes);
                break;
            }
            case 'D': {
                std::string reply;
                put32(reply, r.u32());
                if (!seat.chain || !seat.memory.at) {
                    put32(reply, 0);
                    put32(reply, 0);
                    put32(reply, 0);
                    say('P', reply);
                    break;
                }
                double took = seat.draw(world);
                if (replay) { played.push_back(took); }
                put32(reply, uint32_t(seat.wide));
                put32(reply, uint32_t(seat.tall));
                put32(reply, uint32_t(took));
                say('P', reply);
                break;
            }
            case 'p': {
                std::string path = r.named();
                int w = int(r.u32()), h = int(r.u32());
                bool whole = w > 0 && h > 0 && r.left() >= size_t(w) * size_t(h) * 4;
                world.picture(path, whole ? w : 0, whole ? h : 0, whole ? r.rest() : nullptr);
                if (world.stale()) { say('C', ""); }
                break;
            }
            case 'f': {
                std::string path = r.named();
                bool found = r.left() > 0 && *r.rest() != 0;
                r.at += r.left() > 0 ? 1 : 0;
                if (!sound.file(path, r.rest(), r.left(), found)) { world.file(path, r.rest(), r.left(), found); }
                if (world.stale()) { say('C', ""); }
                break;
            }
            case 't': {
                std::string id = r.named();
                world.terrain(id, r.rest(), r.left());
                if (world.stale()) { say('C', ""); }
                break;
            }
            case 'l': {
                std::string words = r.named(), colour = r.named();
                int w = int(r.u32()), h = int(r.u32());
                if (w > 0 && h > 0 && r.left() >= size_t(w) * size_t(h) * 4) { world.label(words, colour, w, h, r.rest()); }
                if (world.stale()) { say('C', ""); }
                break;
            }
            case 'V':
                sound.loud(body.empty() ? 1.0f : float(body[0]) / 255.0f);
                break;
            case 'A': {
                if (replay || body.empty()) { break; }
                int what = body[0];
                r.at = 1;
                std::string name = r.named();
                float loud = r.left() > 0 ? float(*r.rest()) / 255.0f : 1.0f;
                if (what == 0) {
                    sound.shut(name);
                } else if (what == 1) {
                    sound.open(name, loud);
                } else if (what == 2) {
                    sound.feed(name, r.rest(), r.left());
                } else if (what == 3) {
                    sound.turn(name, loud);
                }
                break;
            }
            default:
                break;
            }
        }
        if (replay && seat.chain && seat.memory.at) {
            double sum = 0;
            for (int i = 0; i < times + 3; i++) {
                double took = seat.draw(world);
                if (i >= 3) { sum += took; }
            }
            if (times > 0) {
                double moving = 0;
                size_t last = std::min(played.size(), size_t(times));
                for (size_t i = played.size() - last; i < played.size(); i++) { moving += played[i]; }
                fprintf(stderr, "%dx%d: %.2f ms a frame as played (%zu), %.2f ms standing still (%d)\n", seat.wide, seat.tall,
                    last ? moving / double(last) / 1000 : 0.0, last, sum / times / 1000, times);
            }
            if (shot) {
                if (FILE* f = fopen(shot, "wb")) {
                    fprintf(f, "P6\n%d %d\n255\n", seat.wide, seat.tall);
                    for (size_t i = 0; i < size_t(seat.wide) * size_t(seat.tall); i++) {
                        const uint8_t* p = seat.memory.at + i * 4;
                        const uint8_t rgb[3] = {p[2], p[1], p[0]};
                        fwrite(rgb, 1, 3, f);
                    }
                    fclose(f);
                }
            }
        }
        // Nothing is taken down piece by piece: the process ends and the system has it all back at once.
        fflush(nullptr);
        std::_Exit(0);
    }
}
