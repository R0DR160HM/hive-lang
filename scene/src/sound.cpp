#include "sound.h"

#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#undef STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <thread>

namespace hive {

namespace {

const float RATE = 48000.0f;
const float TAU = 6.28318530718f;
const int CHUNK = 128;

// A value drawn toward where it was told to go, so that nothing clicks.
struct Glide {
    float now = 0, want = 0, over = 0.05f;
    void to(float v, float seconds) {
        want = v;
        over = seconds;
    }
    float step(float seconds) {
        now += (want - now) * (1 - std::exp(-seconds / std::max(over, 0.0001f)));
        return now;
    }
};

struct Filter {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, x1 = 0, x2 = 0, y1 = 0, y2 = 0;

    void low(float hz, float peakDb) {
        float w = TAU * std::min(hz, RATE * 0.45f) / RATE, cs = std::cos(w);
        float alpha = std::sin(w) / (2 * std::pow(10.0f, peakDb / 20));
        float a0 = 1 + alpha;
        b0 = (1 - cs) / 2 / a0;
        b1 = (1 - cs) / a0;
        b2 = b0;
        a1 = -2 * cs / a0;
        a2 = (1 - alpha) / a0;
    }

    void band(float hz, float q) {
        float w = TAU * std::min(std::max(hz, 10.0f), RATE * 0.45f) / RATE, cs = std::cos(w);
        float alpha = std::sin(w) / (2 * q);
        float a0 = 1 + alpha;
        b0 = alpha / a0;
        b1 = 0;
        b2 = -alpha / a0;
        a1 = -2 * cs / a0;
        a2 = (1 - alpha) / a0;
    }

    float run(float x) {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        return y;
    }
};

enum Shape { SINE, SAW, SQUARE, TRIANGLE };

// A saw's edge smoothed over two samples, or what is above half the rate folds back as a whistle.
float edge(float t, float dt) {
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1;
    }
    if (t > 1 - dt) {
        t = (t - 1) / dt;
        return t * t + t + t + 1;
    }
    return 0;
}

struct Tone {
    float phase = 0;
    float run(float hz, Shape shape) {
        float dt = hz / RATE, t = phase, out = 0;
        phase += dt;
        if (phase >= 1) { phase -= std::floor(phase); }
        switch (shape) {
        case SINE: out = std::sin(TAU * t); break;
        case SAW: out = 2 * t - 1 - edge(t, dt); break;
        case SQUARE: {
            float half = t + 0.5f;
            if (half >= 1) { half -= 1; }
            out = (t < 0.5f ? 1.0f : -1.0f) + edge(t, dt) - edge(half, dt);
            break;
        }
        case TRIANGLE: out = 4 * std::fabs(t - 0.5f) - 1; break;
        }
        return out;
    }
};

struct Clip {
    std::vector<int16_t> frames; // left, right
    std::atomic<bool> ready{false};
    std::atomic<bool> failed{false};
};

struct Note {
    Tone tone;
    float hz, loud, run, age = 0;
    Shape shape;
};

float ramp(float from, float to, float t) { return from * std::pow(to / from, std::min(1.0f, std::max(0.0f, t))); }

struct Voice {
    std::string kind, track;
    bool struck = false, sited = true, gone = false, done = false;
    float goneFor = 0, age = 0;
    Glide gain;
    float loud = 1, pitch = 1;
    float at[3] = {0, 0, 0};
    float left = 0.7f, right = 0.7f;

    Tone first, second, swell;
    Filter filter;
    Glide hz, pass, speed;
    size_t hiss = 0;

    std::vector<Note> notes;
    float next = 0;
    int step = 0;

    std::shared_ptr<Clip> clip;
    double cursor = 0;
};

const int TUNE[4][4] = {{-12, 0, 3, 7}, {-10, 2, 5, 9}, {-15, -3, 0, 4}, {-8, 0, 4, 7}};

float noteOf(int step) { return 55 * std::pow(2.0f, float(step) / 12); }

bool strikes(const std::string& kind) { return kind == "Impact" || kind == "Chime" || kind == "Talk"; }

// A stream's bytes arrive at whatever pace the network keeps, are decoded off to
// one side, and are played out of the two seconds of sound that came of them.
struct Stream {
    static const size_t ROOM = 96000;
    std::mutex lock;
    std::condition_variable woke;
    std::deque<uint8_t> fed;
    bool over = false;
    std::atomic<bool> gone{false}, spent{false};
    std::vector<float> ring = std::vector<float>(ROOM * 2);
    std::atomic<size_t> wrote{0}, read{0};
    std::atomic<float> volume{1};
    bool going = false, said = false;
};

size_t taken(Stream& s, uint8_t* out, size_t want) {
    std::unique_lock<std::mutex> held(s.lock);
    s.woke.wait(held, [&] { return s.fed.size() >= want || s.over || s.gone; });
    size_t n = s.gone ? 0 : std::min(want, s.fed.size());
    if (out) { std::copy(s.fed.begin(), s.fed.begin() + long(n), out); }
    s.fed.erase(s.fed.begin(), s.fed.begin() + long(n));
    return n;
}

size_t pulled(void* stream, void* out, size_t want) {
    return taken(*static_cast<Stream*>(stream), static_cast<uint8_t*>(out), want);
}

// What cannot be gone back over can still be skipped.
ma_bool32 skipped(void* stream, int offset, ma_dr_mp3_seek_origin origin) {
    if (origin != ma_dr_mp3_seek_origin_current || offset < 0) { return MA_FALSE; }
    return taken(*static_cast<Stream*>(stream), nullptr, size_t(offset)) == size_t(offset) ? MA_TRUE : MA_FALSE;
}

void pushed(Stream& s, const float* frames, size_t many) {
    size_t at = 0;
    while (at < many && !s.gone) {
        size_t w = s.wrote.load(), held = w - s.read.load();
        if (held >= Stream::ROOM) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }
        size_t n = std::min(many - at, Stream::ROOM - held);
        for (size_t i = 0; i < n; i++) {
            size_t to = ((w + i) % Stream::ROOM) * 2;
            s.ring[to] = frames[(at + i) * 2];
            s.ring[to + 1] = frames[(at + i) * 2 + 1];
        }
        s.wrote.store(w + n);
        at += n;
    }
}

// An MP3 is decoded as it comes, which is what a station sends. Anything else is a
// recording, and is decoded once the whole of it is here.
void played(std::shared_ptr<Stream> s) {
    uint8_t mark[4] = {0, 0, 0, 0};
    {
        std::unique_lock<std::mutex> held(s->lock);
        s->woke.wait(held, [&] { return s->fed.size() >= 4 || s->over || s->gone; });
        for (size_t i = 0; i < 4 && i < s->fed.size(); i++) { mark[i] = s->fed[i]; }
    }
    bool whole = !memcmp(mark, "OggS", 4) || !memcmp(mark, "fLaC", 4) || !memcmp(mark, "RIFF", 4);
    if (whole) {
        std::vector<uint8_t> bytes;
        {
            std::unique_lock<std::mutex> held(s->lock);
            s->woke.wait(held, [&] { return s->over || s->gone; });
            bytes.assign(s->fed.begin(), s->fed.end());
            s->fed.clear();
        }
        ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 2, ma_uint32(RATE));
        ma_uint64 frames = 0;
        void* pcm = nullptr;
        if (!s->gone && ma_decode_memory(bytes.data(), bytes.size(), &config, &frames, &pcm) == MA_SUCCESS) {
            pushed(*s, static_cast<float*>(pcm), size_t(frames));
            ma_free(pcm, nullptr);
        }
        s->spent = true;
        return;
    }
    ma_dr_mp3 mp3;
    if (!ma_dr_mp3_init(&mp3, pulled, skipped, s.get(), nullptr)) {
        s->spent = true;
        return;
    }
    ma_data_converter_config shape = ma_data_converter_config_init(ma_format_f32, ma_format_f32, mp3.channels, 2,
        mp3.sampleRate, ma_uint32(RATE));
    ma_data_converter fitted;
    if (ma_data_converter_init(&shape, nullptr, &fitted) == MA_SUCCESS) {
        std::vector<float> in(1152 * mp3.channels), out(4096 * 2);
        while (!s->gone) {
            ma_uint64 got = ma_dr_mp3_read_pcm_frames_f32(&mp3, 1152, in.data());
            if (got == 0) { break; }
            ma_uint64 at = 0;
            while (at < got) {
                ma_uint64 took = got - at, made = 4096;
                if (ma_data_converter_process_pcm_frames(&fitted, in.data() + at * mp3.channels, &took, out.data(),
                        &made) != MA_SUCCESS || (took == 0 && made == 0)) {
                    break;
                }
                pushed(*s, out.data(), size_t(made));
                at += took;
            }
        }
        ma_data_converter_uninit(&fitted, nullptr);
    }
    ma_dr_mp3_uninit(&mp3);
    s->spent = true;
}

} // namespace

struct Sound::Inner {
    std::function<void(const std::string&)> want;
    std::mutex lock;
    ma_device device;
    bool opened = false, tried = false;
    std::vector<float> hiss;
    std::map<std::string, std::shared_ptr<Voice>> named;
    std::vector<std::shared_ptr<Voice>> sounding;
    std::map<std::string, std::shared_ptr<Clip>> clips;
    std::set<std::string> asked;
    float ear[3] = {0, 0, 0}, ahead[3] = {0, 0, -1};
    float master = 0.8f, level = 1;
    std::map<std::string, std::shared_ptr<Stream>> streams;

    bool open() {
        if (tried) { return opened; }
        tried = true;
        hiss.resize(size_t(RATE) * 2);
        uint32_t seed = 22222;
        for (auto& v : hiss) {
            seed = seed * 1664525u + 1013904223u;
            v = float(seed >> 8) / 8388608.0f - 1;
        }
        ma_device_config config = ma_device_config_init(ma_device_type_playback);
        config.playback.format = ma_format_f32;
        config.playback.channels = 2;
        config.sampleRate = ma_uint32(RATE);
        config.dataCallback = [](ma_device* d, void* out, const void*, ma_uint32 frames) {
            static_cast<Inner*>(d->pUserData)->mix(static_cast<float*>(out), frames);
        };
        config.pUserData = this;
        if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS) { return false; }
        if (ma_device_start(&device) != MA_SUCCESS) {
            ma_device_uninit(&device);
            return false;
        }
        opened = true;
        return true;
    }

    std::shared_ptr<Clip> recorded(const std::string& path) {
        auto found = clips.find(path);
        if (found != clips.end()) { return found->second; }
        auto clip = std::make_shared<Clip>();
        clips[path] = clip;
        asked.insert(path);
        want(path);
        return clip;
    }

    void place(Voice& v) {
        if (!v.sited) {
            v.left = v.right = 1;
            return;
        }
        float to[3] = {v.at[0] - ear[0], v.at[1] - ear[1], v.at[2] - ear[2]};
        float away = std::sqrt(to[0] * to[0] + to[1] * to[1] + to[2] * to[2]);
        float heard = 7 / (7 + 1.2f * (std::min(std::max(away, 7.0f), 400.0f) - 7));
        float side = 0.5f;
        if (away > 0.0001f) {
            float rightward[3] = {-ahead[2], 0, ahead[0]};
            float len = std::sqrt(rightward[0] * rightward[0] + rightward[2] * rightward[2]);
            if (len > 0.0001f) {
                float flat = std::sqrt(to[0] * to[0] + to[2] * to[2]);
                if (flat > 0.0001f) {
                    float across = (to[0] * rightward[0] + to[2] * rightward[2]) / (len * flat);
                    side = 0.5f + 0.5f * std::min(1.0f, std::max(-1.0f, across));
                }
            }
        }
        v.left = std::cos(side * TAU / 4) * heard;
        v.right = std::sin(side * TAU / 4) * heard;
    }

    void bend(Voice& v) {
        float p = v.pitch;
        if (v.clip) {
            v.speed.to(std::max(0.06f, p), 0.08f);
        } else if (v.kind == "Engine") {
            float revs = std::max(18.0f, 54 * p);
            v.hz.to(revs, 0.04f);
            v.pass.to(340 + revs * 11, 0.06f);
        } else if (v.kind == "Tyres") {
            v.pass.to(std::max(120.0f, 780 * p), 0.05f);
        } else if (v.kind == "Brakes") {
            v.pass.to(std::max(400.0f, 2400 * p), 0.03f);
            v.hz.to(std::max(300.0f, 1750 * p), 0.03f);
        } else if (v.kind == "Wind") {
            v.pass.to(std::max(90.0f, 320 * p), 0.1f);
        } else if (v.kind == "Crowd") {
            v.pass.to(std::max(180.0f, 620 * p), 0.25f);
        }
    }

    std::shared_ptr<Voice> sustained(const std::string& kind, const std::string& track) {
        auto v = std::make_shared<Voice>();
        v->kind = kind;
        v->track = track;
        v->sited = kind != "Music";
        v->hz.now = 54;
        v->pass.now = kind == "Crowd" ? 620.0f : 600.0f;
        v->speed.now = 1;
        if (!track.empty()) { v->clip = recorded(track); }
        return v;
    }

    void strike(const std::string& kind, const Heard& s) {
        auto v = std::make_shared<Voice>();
        v->kind = kind;
        v->track = s.track;
        v->struck = true;
        v->sited = kind != "Talk";
        v->loud = std::max(0.0001f, s.volume);
        v->pitch = s.pitch;
        for (int i = 0; i < 3; i++) { v->at[i] = s.p[i]; }
        if (!s.track.empty()) {
            v->clip = recorded(s.track);
            if (!v->clip->ready) { return; }
            v->speed.now = v->speed.want = std::max(0.06f, s.pitch);
        }
        place(*v);
        sounding.push_back(v);
    }

    void hear(const std::vector<const Heard*>& list, const Eye& eye) {
        if (list.empty() && named.empty()) { return; }
        if (!open()) { return; }
        std::lock_guard<std::mutex> held(lock);
        for (int i = 0; i < 3; i++) { ear[i] = eye.eye[i]; }
        ahead[0] = -std::sin(eye.aim[0]) * std::cos(eye.aim[1]);
        ahead[1] = std::sin(eye.aim[1]);
        ahead[2] = -std::cos(eye.aim[0]) * std::cos(eye.aim[1]);
        std::set<std::string> here;
        for (const Heard* s : list) {
            std::string kind = s->voice.empty() ? "Engine" : s->voice;
            here.insert(s->name);
            auto found = named.find(s->name);
            if (found != named.end() && (found->second->kind != kind || found->second->track != s->track)) {
                hush(found->second);
                named.erase(found);
                found = named.end();
            }
            if (found == named.end()) {
                if (strikes(kind)) {
                    strike(kind, *s);
                    auto mark = std::make_shared<Voice>();
                    mark->kind = kind;
                    mark->track = s->track;
                    mark->struck = true;
                    named[s->name] = mark;
                    continue;
                }
                auto v = sustained(kind, s->track);
                sounding.push_back(v);
                found = named.emplace(s->name, v).first;
            }
            Voice& v = *found->second;
            if (v.struck) { continue; }
            for (int i = 0; i < 3; i++) { v.at[i] = s->p[i]; }
            v.gain.to(std::max(0.0f, s->volume), 0.06f);
            v.pitch = s->pitch;
            bend(v);
        }
        for (auto it = named.begin(); it != named.end();) {
            if (here.count(it->first)) {
                ++it;
                continue;
            }
            hush(it->second);
            it = named.erase(it);
        }
    }

    void hush(const std::shared_ptr<Voice>& v) {
        if (v->struck) { return; }
        v->gone = true;
        v->gain.to(0, 0.05f);
    }

    float sample(Voice& v, float& other) {
        Clip& c = *v.clip;
        size_t many = c.frames.size() / 2;
        if (many == 0) { return 0; }
        size_t at = size_t(v.cursor);
        if (at >= many) {
            if (v.struck) {
                v.done = true;
                return 0;
            }
            v.cursor = std::fmod(v.cursor, double(many));
            at = size_t(v.cursor);
        }
        size_t after = at + 1 < many ? at + 1 : (v.struck ? at : 0);
        float t = float(v.cursor - double(at));
        float l = (float(c.frames[at * 2]) * (1 - t) + float(c.frames[after * 2]) * t) / 32768.0f;
        float r = (float(c.frames[at * 2 + 1]) * (1 - t) + float(c.frames[after * 2 + 1]) * t) / 32768.0f;
        v.cursor += double(v.speed.now);
        other = r;
        return l;
    }

    void render(Voice& v, float* left, float* right, int frames) {
        const float span = float(frames) / RATE;
        place(v);
        if (v.clip) {
            if (!v.clip->ready) {
                if (v.clip->failed && !v.struck) { v.clip.reset(); }
                return;
            }
            v.speed.step(span);
            float loud = v.struck ? v.loud : v.gain.step(span);
            for (int i = 0; i < frames; i++) {
                float r = 0, l = sample(v, r);
                if (v.sited) {
                    float both = (l + r) * 0.5f * loud;
                    left[i] += both * v.left;
                    right[i] += both * v.right;
                } else {
                    left[i] += l * loud;
                    right[i] += r * loud;
                }
            }
            return;
        }
        float mono[CHUNK];
        if (v.struck) {
            for (int i = 0; i < frames; i++) {
                float t = v.age + float(i) / RATE, out = 0;
                if (v.kind == "Chime") {
                    float env = t < 0.01f ? ramp(0.0001f, v.loud, t / 0.01f) : ramp(v.loud, 0.0001f, (t - 0.01f) / 0.54f);
                    out = v.first.run(std::max(80.0f, 660 * v.pitch), SINE) * env;
                    if (t > 0.6f) { v.done = true; }
                } else {
                    if (i == 0) { v.filter.low(ramp(std::max(400.0f, 3200 * v.pitch), 200, t / 0.3f), 0); }
                    float burst = v.filter.run(hiss[v.hiss++ % hiss.size()]);
                    float thud = v.second.run(ramp(std::max(50.0f, 150 * v.pitch), 45, t / 0.22f), SINE) * 0.7f;
                    out = (burst + thud) * ramp(v.loud, 0.0001f, t / 0.38f);
                    if (t > 0.4f) { v.done = true; }
                }
                mono[i] = out;
            }
            v.age += span;
        } else {
            float loud = v.gain.step(span);
            if (v.kind == "Engine") {
                float revs = v.hz.step(span);
                v.filter.low(v.pass.step(span), 3.5f);
                for (int i = 0; i < frames; i++) {
                    mono[i] = v.filter.run(v.first.run(revs, SAW) + v.second.run(revs * 0.5f, SQUARE)) * loud;
                }
            } else if (v.kind == "Tyres" || v.kind == "Wind") {
                v.filter.band(v.pass.step(span), v.kind == "Tyres" ? 1.1f : 0.4f);
                for (int i = 0; i < frames; i++) { mono[i] = v.filter.run(hiss[v.hiss++ % hiss.size()]) * loud; }
            } else if (v.kind == "Brakes") {
                v.filter.band(v.pass.step(span), 9);
                float cry = v.hz.step(span);
                for (int i = 0; i < frames; i++) {
                    mono[i] = (v.filter.run(hiss[v.hiss++ % hiss.size()]) + v.first.run(cry, TRIANGLE) * 0.16f) * loud;
                }
            } else if (v.kind == "Crowd") {
                float centre = v.pass.step(span);
                for (int i = 0; i < frames; i++) {
                    if ((i & 31) == 0) { v.filter.band(centre + v.swell.run(0.13f * 32, SINE) * 260, 0.8f); }
                    mono[i] = v.filter.run(hiss[v.hiss++ % hiss.size()]) * loud;
                }
            } else if (v.kind == "Music") {
                for (int i = 0; i < frames; i++) {
                    if (v.next <= 0) {
                        int beat = v.step % 8, bar = (v.step / 8) % 4;
                        if (beat == 0 || beat == 5) {
                            v.notes.push_back(Note{Tone(), noteOf(TUNE[bar][0]), 0.5f, 0.5f, 0, TRIANGLE});
                        }
                        v.notes.push_back(Note{Tone(), noteOf(TUNE[bar][1 + v.step % 3] + 12), 0.1f, 0.22f, 0, SQUARE});
                        v.next += 0.19f;
                        v.step++;
                    }
                    v.next -= 1 / RATE;
                    float out = 0;
                    for (auto& n : v.notes) {
                        float env = n.age < 0.012f ? ramp(0.0001f, n.loud, n.age / 0.012f)
                            : ramp(n.loud, 0.0001f, (n.age - 0.012f) / (n.run - 0.012f));
                        out += n.tone.run(n.hz, n.shape) * env;
                        n.age += 1 / RATE;
                    }
                    mono[i] = out * loud;
                }
                v.notes.erase(std::remove_if(v.notes.begin(), v.notes.end(), [](const Note& n) {
                    return n.age > n.run + 0.02f;
                }), v.notes.end());
            } else {
                for (int i = 0; i < frames; i++) { mono[i] = 0; }
            }
        }
        for (int i = 0; i < frames; i++) {
            left[i] += mono[i] * v.left;
            right[i] += mono[i] * v.right;
        }
    }

    // Nothing is heard until a quarter of a second is in hand, and a stream that
    // runs dry waits for that much again rather than stuttering.
    void tuned(Stream& s, float* left, float* right, int many) {
        size_t r = s.read.load(), held = s.wrote.load() - r;
        if (!s.going) { s.going = held >= size_t(RATE) / 4 || (s.spent && held > 0); }
        if (!s.going) { return; }
        size_t n = std::min(held, size_t(many));
        float loud = s.volume.load();
        for (size_t i = 0; i < n; i++) {
            size_t from = ((r + i) % Stream::ROOM) * 2;
            left[i] += s.ring[from] * loud;
            right[i] += s.ring[from + 1] * loud;
        }
        s.read.store(r + n);
        if (n < size_t(many)) { s.going = false; }
    }

    void mix(float* out, ma_uint32 frames) {
        std::lock_guard<std::mutex> held(lock);
        float left[CHUNK], right[CHUNK];
        ma_uint32 at = 0;
        while (at < frames) {
            int many = int(std::min<ma_uint32>(CHUNK, frames - at));
            for (int i = 0; i < many; i++) { left[i] = right[i] = 0; }
            for (auto& v : sounding) {
                render(*v, left, right, many);
                if (v->gone) {
                    v->goneFor += float(many) / RATE;
                    if (v->goneFor > 0.3f) { v->done = true; }
                }
            }
            sounding.erase(std::remove_if(sounding.begin(), sounding.end(),
                [](const std::shared_ptr<Voice>& v) { return v->done; }), sounding.end());
            float loud = master * level;
            for (int i = 0; i < many; i++) {
                left[i] *= loud;
                right[i] *= loud;
            }
            for (auto& named : streams) { tuned(*named.second, left, right, many); }
            for (int i = 0; i < many; i++) {
                out[(at + ma_uint32(i)) * 2] = std::min(1.0f, std::max(-1.0f, left[i]));
                out[(at + ma_uint32(i)) * 2 + 1] = std::min(1.0f, std::max(-1.0f, right[i]));
            }
            at += ma_uint32(many);
        }
    }
};

Sound::Sound(std::function<void(const std::string&)> want) : in(new Inner()) { in->want = std::move(want); }

Sound::~Sound() {
    if (in->opened) { ma_device_uninit(&in->device); }
}

void Sound::hear(const std::vector<const Heard*>& sounds, const Eye& eye) { in->hear(sounds, eye); }

bool Sound::file(const std::string& path, const uint8_t* data, size_t size, bool found) {
    std::shared_ptr<Clip> clip;
    {
        std::lock_guard<std::mutex> held(in->lock);
        if (!in->asked.count(path)) { return false; }
        in->asked.erase(path);
        clip = in->clips[path];
    }
    if (!found || size == 0) {
        clip->failed = true;
        return true;
    }
    // Decoded off to one side: a recording is seconds of work and a frame is not.
    std::vector<uint8_t> bytes(data, data + size);
    std::thread([clip, bytes]() {
        ma_decoder_config config = ma_decoder_config_init(ma_format_s16, 2, ma_uint32(RATE));
        ma_uint64 frames = 0;
        void* pcm = nullptr;
        if (ma_decode_memory(bytes.data(), bytes.size(), &config, &frames, &pcm) != MA_SUCCESS || frames == 0) {
            clip->failed = true;
            return;
        }
        clip->frames.assign(static_cast<int16_t*>(pcm), static_cast<int16_t*>(pcm) + frames * 2);
        ma_free(pcm, nullptr);
        clip->ready = true;
    }).detach();
    return true;
}

void Sound::loud(float volume) {
    std::lock_guard<std::mutex> held(in->lock);
    in->level = volume;
}

void Sound::open(const std::string& name, float volume) {
    shut(name);
    if (!in->open()) { return; }
    auto stream = std::make_shared<Stream>();
    stream->volume = volume;
    {
        std::lock_guard<std::mutex> held(in->lock);
        in->streams[name] = stream;
    }
    std::thread(played, stream).detach();
}

void Sound::feed(const std::string& name, const uint8_t* data, size_t size) {
    std::shared_ptr<Stream> stream;
    {
        std::lock_guard<std::mutex> held(in->lock);
        auto found = in->streams.find(name);
        if (found == in->streams.end()) { return; }
        stream = found->second;
    }
    {
        std::lock_guard<std::mutex> held(stream->lock);
        if (size == 0) {
            stream->over = true;
        } else {
            stream->fed.insert(stream->fed.end(), data, data + size);
        }
    }
    stream->woke.notify_all();
}

void Sound::turn(const std::string& name, float volume) {
    std::lock_guard<std::mutex> held(in->lock);
    auto found = in->streams.find(name);
    if (found != in->streams.end()) { found->second->volume = volume; }
}

void Sound::shut(const std::string& name) {
    std::shared_ptr<Stream> stream;
    {
        std::lock_guard<std::mutex> held(in->lock);
        auto found = in->streams.find(name);
        if (found == in->streams.end()) { return; }
        stream = found->second;
        in->streams.erase(found);
    }
    {
        std::lock_guard<std::mutex> held(stream->lock);
        stream->gone = true;
    }
    stream->woke.notify_all();
}

std::vector<std::string> Sound::spent() {
    std::vector<std::string> names;
    std::lock_guard<std::mutex> held(in->lock);
    for (auto& named : in->streams) {
        Stream& s = *named.second;
        if (!s.said && s.spent && s.wrote.load() == s.read.load()) {
            s.said = true;
            names.push_back(named.first);
        }
    }
    return names;
}

} // namespace hive
