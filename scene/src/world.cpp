#include "world.h"

#include "baked.h"
#include "colour.h"
#include "model.h"
#include "shapes.h"
#include "surfaces.h"
#include "wire.h"

#include <backend/BufferDescriptor.h>
#include <backend/PixelBufferDescriptor.h>
#include <filament/Box.h>
#include <filament/Camera.h>
#include <filament/ColorGrading.h>
#include <filament/Engine.h>
#include <filament/IndexBuffer.h>
#include <filament/IndirectLight.h>
#include <filament/LightManager.h>
#include <filament/Material.h>
#include <filament/MaterialInstance.h>
#include <filament/RenderTarget.h>
#include <filament/RenderableManager.h>
#include <filament/Renderer.h>
#include <filament/Scene.h>
#include <filament/Skybox.h>
#include <filament/Texture.h>
#include <filament/TextureSampler.h>
#include <filament/ToneMapper.h>
#include <filament/TransformManager.h>
#include <filament/VertexBuffer.h>
#include <filament/View.h>
#include <filament/Viewport.h>
#include <math/mat3.h>
#include <math/mat4.h>
#include <math/quat.h>
#include <math/vec3.h>
#include <math/vec4.h>
#include <utils/EntityManager.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <unordered_map>

using namespace filament;
using namespace filament::math;
using utils::Entity;
using utils::EntityManager;

namespace hive {

namespace {

enum Kind { BOX, SPHERE, CYLINDER, CONE, GROUND, LABEL, LINE, SOUND, SPRITE, ROOF, FIGURE, TERRAIN, KINDS };

const int HAS_AT = 1, HAS_TURN = 2, HAS_SIZE = 4, HAS_SURFACE = 8, HAS_WORDS = 16, HAS_VOICE = 32, HAS_TRACK = 64,
    HAS_PAINTS = 128, HAS_SCALE = 32;
const int EYE_LENS = 1, EYE_FOG = 2, EYE_SKY = 4, EYE_GRAB = 8, EYE_FLAT = 16, EYE_GRAIN = 32, EYE_BITS = 64,
    EYE_SUN = 128;

const int PER_ROW = 256;
const int ROW_TEXELS = PER_ROW * 4;
const int MOST_SEATS = 127 * PER_ROW;
const int POOL_ROWS = 64;
const int SHADOW_MAP = 2048;
const int SKY_FACE = 128;
const int GLOW_FACE = 32;
const int GLOW_LEVELS = 4;
const float PI_F = 3.14159265358979f;

// Khronos's neutral curve without its toe, in sRGB primaries though Filament hands over Rec.2020.
struct Shoulder final : public ToneMapper {
    static float3 curve(float3 c) {
        float peak = std::max(c.r, std::max(c.g, c.b));
        if (peak < 0.8f) { return c; }
        float fresh = 1.0f - 0.04f / (peak - 0.6f);
        c *= fresh / peak;
        float g = 1.0f - 1.0f / (0.15f * (peak - fresh) + 1.0f);
        return c + (float3(fresh) - c) * g;
    }
    float3 operator()(float3 c) const noexcept override {
        float3 s{1.660491f * c.r - 0.587641f * c.g - 0.072850f * c.b,
            -0.124550f * c.r + 1.132900f * c.g - 0.008349f * c.b,
            -0.018151f * c.r - 0.100579f * c.g + 1.118730f * c.b};
        s = curve(max(s, float3(0.0f)));
        return float3{0.627404f * s.r + 0.329283f * s.g + 0.043313f * s.b,
            0.069097f * s.r + 0.919540f * s.g + 0.011362f * s.b,
            0.016391f * s.r + 0.088013f * s.g + 0.895595f * s.b};
    }
};

// The colour the curve above brings out as `shown`.
float3 unshouldered(float3 shown) {
    float peak = std::max(shown.r, std::max(shown.g, shown.b));
    if (peak < 0.8f) { return shown; }
    // Past this the curve drains a colour toward grey faster than it brightens it.
    float fresh = std::min(peak, 0.94f);
    float3 want = shown * (fresh / peak);
    float lit = 0.6f + 0.04f / (1.0f - fresh);
    float g = 1.0f - 1.0f / (0.15f * (lit - fresh) + 1.0f);
    float3 before = (want - float3(fresh) * g) / (1.0f - g);
    return max(before, float3(0.0f)) * (lit / fresh);
}

void freed(void* buffer, size_t, void*) { free(buffer); }

backend::BufferDescriptor kept(const void* data, size_t size) {
    void* copy = malloc(size);
    memcpy(copy, data, size);
    return backend::BufferDescriptor(copy, size, freed);
}

Texture::PixelBufferDescriptor pixels(const void* data, size_t size, Texture::Format format, Texture::Type type) {
    void* copy = malloc(size);
    memcpy(copy, data, size);
    return Texture::PixelBufferDescriptor(copy, size, format, type, freed);
}

struct Turn {
    float m[9]; // column by column
};

// Yaw, then pitch about the shape's own lateral axis, then roll about its length.
Turn turned(float x, float y, float z) {
    float a = std::cos(x), b = std::sin(x), c = std::cos(y), d = std::sin(y), e = std::cos(z), f = std::sin(z);
    float ce = c * e, cf = c * f, de = d * e, df = d * f;
    return Turn{{ce + df * b, a * f, cf * b - de, de * b - cf, a * e, df + ce * b, a * d, -b, a * c}};
}

void placed(float* row, const float p[3], const Turn& t, const float s[3]) {
    row[0] = t.m[0] * s[0];
    row[1] = t.m[3] * s[1];
    row[2] = t.m[6] * s[2];
    row[3] = p[0];
    row[4] = t.m[1] * s[0];
    row[5] = t.m[4] * s[1];
    row[6] = t.m[7] * s[2];
    row[7] = p[1];
    row[8] = t.m[2] * s[0];
    row[9] = t.m[5] * s[1];
    row[10] = t.m[8] * s[2];
    row[11] = p[2];
}

quatf spun(float x, float y, float z) {
    float c1 = std::cos(x / 2), c2 = std::cos(y / 2), c3 = std::cos(z / 2);
    float s1 = std::sin(x / 2), s2 = std::sin(y / 2), s3 = std::sin(z / 2);
    return quatf{c1 * c2 * c3 + s1 * s2 * s3, s1 * c2 * c3 + c1 * s2 * s3, c1 * s2 * c3 - s1 * c2 * s3,
        c1 * c2 * s3 - s1 * s2 * c3};
}

mat4f composed(const float t[3], quatf q, const float s[3]) {
    mat4f m(q);
    m[0] *= s[0];
    m[1] *= s[1];
    m[2] *= s[2];
    m[3] = float4{t[0], t[1], t[2], 1.0f};
    return m;
}

quatf framed(const float* facing, const float* along) {
    float3 n = normalize(float3{facing[0], facing[1], facing[2]});
    float3 t{along[0], along[1], along[2]};
    t = t - n * dot(n, t);
    if (dot(t, t) < 1e-8f) {
        t = std::fabs(n.x) < 0.9f ? cross(float3{1, 0, 0}, n) : cross(float3{0, 1, 0}, n);
    }
    t = normalize(t);
    float3 b = cross(n, t);
    return mat3f::packTangentFrame(mat3f{t, b, n});
}

struct Form {
    VertexBuffer* points = nullptr;
    IndexBuffer* corners = nullptr;
    uint32_t count = 0;
};

struct Coat {
    std::string finish;
    Texture* grain = nullptr;
    Texture* relief = nullptr;
};

struct Thing;

struct Batch {
    Form* form = nullptr;
    MaterialInstance* look = nullptr;
    Texture* things = nullptr;
    std::vector<float> rows;
    std::vector<Thing*> seats;
    int room = 0;
    int low = 1 << 30, high = -1;
    Entity entity;
    bool cast = true, shown = false;
};

struct Crowd {
    std::string path;
    Model model;
    bool failed = false;
    Form form;
    MaterialInstance* look = nullptr;
    Texture* bones = nullptr;
    Texture* paints = nullptr;
    std::vector<float> boneRows, paintRows;
    std::vector<Thing*> seats;
    int room = 0, wide = 4;
    int low = 1 << 30, high = -1;
    float reach = 1;
    Entity entity;
    bool shown = false;
};

struct Shared {
    Texture* texture = nullptr;
    float aspect = 1;
    bool asked = false;
    std::vector<Thing*> users;
};

struct Land {
    Form form;
    int wide = 0, rows = 0;
    float cell = 0, reach = 1;
    std::string asked, laid;
};

struct Thing {
    int kind = BOX;
    std::string key, words, tint, finish;
    float dims[2] = {0, 0};
    bool soft = false, visible = true;
    uint32_t carry = 0;

    Batch* batch = nullptr;
    Crowd* crowd = nullptr;
    int index = -1;
    float at[3] = {0, 0, 0}, turn[3] = {0, 0, 0}, size[3] = {1, 1, 1};
    std::vector<float> pose;
    std::vector<std::string> paints;

    Entity entity;
    bool standing = false, staged = false;
    MaterialInstance* look = nullptr;
    int slot = -1;
    Shared* shared = nullptr;
    Land* land = nullptr;
    float ends[6] = {0, 0, 0, 0, 0, 0};
    Colour stroke;
};

struct Record {
    int kind = BOX;
    std::string c, s, x;
    float p[3] = {0, 0, 0}, r[3] = {0, 0, 0}, z[3] = {1, 1, 1};
    std::vector<float> d;
    std::vector<std::string> t;
    bool turned = false;
};

struct Sight {
    Camera* camera = nullptr;
    Entity holder;
    View* view = nullptr;
    Texture* colour = nullptr;
    RenderTarget* target = nullptr;
    int wide = 0, tall = 0;
    Entity quad;
    MaterialInstance* sheet = nullptr;
    VertexBuffer* corners = nullptr;
    bool staged = false;
};

std::string finishOf(const Record& s) {
    if (!s.s.empty()) { return s.s; }
    if (s.kind == GROUND || s.kind == TERRAIN) { return "Turf"; }
    if (s.kind == CYLINDER || s.kind == CONE) { return "Staves"; }
    if (s.kind == SPHERE) { return "Speckle"; }
    return "Planks";
}

const char* const FORMS[KINDS] = {"box", "sphere", "cylinder", "cone", "ground", "label", "line", "sound", "sprite",
    "roof", "figure", "terrain"};

std::string formOf(const Record& s) {
    if (s.kind != CONE) { return FORMS[s.kind]; }
    float top = s.d.size() > 0 ? s.d[0] : 1, bottom = s.d.size() > 1 ? s.d[1] : 1;
    float m = std::max(top, bottom);
    if (!(m > 0)) { m = 1; }
    return "cone|" + std::to_string(int(std::lround(top / m * 32))) + "|" + std::to_string(int(std::lround(bottom / m * 32)));
}

void stretch(const Record& s, float v[3]) {
    auto d = [&](size_t i) { return i < s.d.size() ? s.d[i] : 1.0f; };
    if (s.kind == SPHERE) {
        v[0] = v[1] = v[2] = d(0);
    } else if (s.kind == CYLINDER) {
        v[0] = v[2] = d(0);
        v[1] = d(1);
    } else if (s.kind == CONE) {
        v[0] = v[2] = std::max(d(0), d(1));
        v[1] = d(2);
    } else if (s.kind == GROUND) {
        v[0] = d(0);
        v[1] = 1;
        v[2] = d(1);
    } else {
        v[0] = d(0);
        v[1] = d(1);
        v[2] = d(2);
    }
    for (int i = 0; i < 3; i++) { v[i] = std::max(v[i], 0.0001f); }
}

float hazeAmount(const Colour& mid) {
    return 0.42f * std::min(1.0f, luma(mid.r, mid.g, mid.b) / 0.35f);
}

float3 lerp3(float3 a, float3 b, float t) { return a + (b - a) * t; }

float3 shownOf(float3 linear) { return float3{encoded(linear.r), encoded(linear.g), encoded(linear.b)}; }
float3 lightOf(float3 shown) { return float3{decoded(shown.r), decoded(shown.g), decoded(shown.b)}; }

// A page's gradient runs between stops in the screen's own values, eight bits each.
float3 banded(const float3* stops, const float* at, int count, float t) {
    if (t <= at[0]) { return stops[0]; }
    for (int i = 0; i + 1 < count; i++) {
        if (t <= at[i + 1]) { return lerp3(stops[i], stops[i + 1], (t - at[i]) / (at[i + 1] - at[i])); }
    }
    return stops[count - 1];
}

float3 quantised(float3 linear) {
    float3 s = shownOf(linear);
    return float3{std::round(s.r * 255) / 255, std::round(s.g * 255) / 255, std::round(s.b * 255) / 255};
}

} // namespace

struct World::Inner {
    Engine& engine;
    Host& host;
    Scene* stage = nullptr;
    Scene* page = nullptr;

    Material* opaque = nullptr;
    Material* pierced = nullptr;
    Material* see = nullptr;
    Material* body = nullptr;
    Material* billboard = nullptr;
    Material* stroke = nullptr;
    Material* sheetOf = nullptr;

    Shoulder shoulder;
    ColorGrading* grading = nullptr;
    Texture* flat = nullptr;
    Texture* blank = nullptr;
    Texture* bayer = nullptr;

    std::unordered_map<std::string, Form> forms;
    std::unordered_map<std::string, Coat> skins;
    std::unordered_map<std::string, Picture> photos;
    std::unordered_map<std::string, bool> photoAsked;
    std::unordered_map<std::string, std::vector<Batch*>> batches;
    std::unordered_map<std::string, Crowd*> crowds;
    std::unordered_map<std::string, Shared*> signs;
    std::unordered_map<std::string, Shared*> pics;
    std::unordered_map<std::string, std::vector<uint8_t>> grounds;
    std::vector<MaterialInstance*> veiled;

    Texture* pool = nullptr;
    std::vector<float> poolRows;
    std::vector<int> poolSpare;
    int poolLow = 1 << 30, poolHigh = -1;

    Form quadForm;
    Form lineForm;
    Entity lineEntity;
    MaterialInstance* lineLook = nullptr;
    std::vector<Thing*> lines;
    int lineRoom = 0;
    bool linesMoved = false, linesShown = false;

    std::vector<Thing*> live;
    std::vector<Heard*> voiceOf;
    std::vector<const Heard*> sounded;
    bool soundsMoved = false;
    uint32_t seq = 0, carry = 0;

    Eye world;
    std::vector<Eye> looks;
    std::vector<Box> boxes;
    std::vector<Sight> insets;
    Sight main;
    View* sheetView = nullptr;
    Camera* sheetCamera = nullptr;
    Entity sheetHolder;

    Entity sun;
    Skybox* sky = nullptr;
    Texture* skyCube = nullptr;
    std::string skyHex;
    bool skyStaged = false;
    IndirectLight* glow = nullptr;
    Texture* glowCube = nullptr;
    std::string glowHex;
    std::chrono::steady_clock::time_point glowAt;
    bool glowMade = false;
    float3 haze{0.2705f, 0.5972f, 1.0f};
    float fogNear = 0, fogFar = 0, fogOn = 0;
    float shadeFar = 55, sunAt[2] = {0, -100};
    bool sunSet = false;

    struct Spent {
        RenderTarget* target;
        Texture* colour;
        int frames;
    };
    std::vector<Spent> spent;

    int sheetWide = 1, sheetTall = 1, drawnWide = 1, drawnTall = 1;
    int coarse = 0, deep = 0;
    bool dirty = true, shaped = true, upside = false, traded = false;

    Inner(Engine& e, Host& h) : engine(e), host(h) {}

    Material* material(const unsigned char* data, size_t size) {
        return Material::Builder().package(data, size).build(engine);
    }

    Texture* texture(int wide, int tall, Texture::InternalFormat format, bool mips, const char* tag = "plain") {
        int levels = 1;
        if (mips) {
            for (int s = std::max(wide, tall); s > 1; s >>= 1) { levels++; }
        }
        Texture::Usage usage = Texture::Usage::DEFAULT;
        if (mips) { usage = usage | Texture::Usage::GEN_MIPMAPPABLE; }
        return Texture::Builder().width(uint32_t(wide)).height(uint32_t(tall)).levels(uint8_t(levels))
            .sampler(Texture::Sampler::SAMPLER_2D).format(format).usage(usage).name(tag, strlen(tag)).build(engine);
    }

    // A page's picture counts its rows down and a texture counts them up.
    Texture* shown(int wide, int tall, const uint8_t* rgba) {
        Texture* t = texture(wide, tall, Texture::InternalFormat::SRGB8_A8, true, "shown");
        std::vector<uint8_t> up(size_t(wide) * tall * 4);
        for (int y = 0; y < tall; y++) {
            memcpy(&up[size_t(tall - 1 - y) * wide * 4], rgba + size_t(y) * wide * 4, size_t(wide) * 4);
        }
        t->setImage(engine, 0, pixels(up.data(), up.size(), Texture::Format::RGBA, Texture::Type::UBYTE));
        t->generateMipmaps(engine);
        return t;
    }

    static TextureSampler tiled() {
        TextureSampler s(TextureSampler::MinFilter::LINEAR_MIPMAP_LINEAR, TextureSampler::MagFilter::LINEAR,
            TextureSampler::WrapMode::REPEAT);
        s.setAnisotropy(4.0f);
        return s;
    }

    static TextureSampler exact() {
        return TextureSampler(TextureSampler::MinFilter::NEAREST, TextureSampler::MagFilter::NEAREST);
    }

    static TextureSampler smooth() {
        return TextureSampler(TextureSampler::MinFilter::LINEAR_MIPMAP_LINEAR, TextureSampler::MagFilter::LINEAR);
    }

    Form formed(const Mesh& m) {
        Form f;
        size_t n = m.count();
        const int wide = 25;
        std::vector<float> data(n * wide);
        for (size_t i = 0; i < n; i++) {
            float* v = &data[i * wide];
            memcpy(v, &m.place[i * 3], 12);
            quatf q = framed(&m.facing[i * 3], &m.along[i * 4]);
            v[3] = q.x;
            v[4] = q.y;
            v[5] = q.z;
            v[6] = q.w;
            v[7] = m.uv[i * 2];
            v[8] = m.uv[i * 2 + 1];
            v[9] = v[10] = v[11] = v[12] = 1;
            memcpy(v + 13, &m.spanU[i * 3], 12);
            v[16] = m.rounding[i];
            memcpy(v + 17, &m.spanV[i * 3], 12);
            v[20] = 0;
            memcpy(v + 21, &m.along[i * 4], 16);
        }
        f.points = solidPoints(uint32_t(n));
        f.points->setBufferAt(engine, 0, kept(data.data(), data.size() * 4));
        f.corners = IndexBuffer::Builder().indexCount(uint32_t(m.index.size())).bufferType(IndexBuffer::IndexType::UINT)
            .build(engine);
        f.corners->setBuffer(engine, kept(m.index.data(), m.index.size() * 4));
        f.count = uint32_t(m.index.size());
        return f;
    }

    VertexBuffer* solidPoints(uint32_t count) {
        const uint8_t stride = 100;
        return VertexBuffer::Builder().vertexCount(count).bufferCount(1)
            .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3, 0, stride)
            .attribute(VertexAttribute::TANGENTS, 0, VertexBuffer::AttributeType::FLOAT4, 12, stride)
            .attribute(VertexAttribute::UV0, 0, VertexBuffer::AttributeType::FLOAT2, 28, stride)
            .attribute(VertexAttribute::COLOR, 0, VertexBuffer::AttributeType::FLOAT4, 36, stride)
            .attribute(VertexAttribute::CUSTOM0, 0, VertexBuffer::AttributeType::FLOAT4, 52, stride)
            .attribute(VertexAttribute::CUSTOM1, 0, VertexBuffer::AttributeType::FLOAT4, 68, stride)
            .attribute(VertexAttribute::CUSTOM2, 0, VertexBuffer::AttributeType::FLOAT4, 84, stride)
            .build(engine);
    }

    Form& unit(const std::string& form) {
        auto found = forms.find(form);
        if (found != forms.end()) { return found->second; }
        return forms.emplace(form, formed(unitMesh(form))).first->second;
    }

    void setup() {
        stage = engine.createScene();
        page = engine.createScene();
        opaque = material(baked::solid_opaque, baked::solid_opaque_size);
        pierced = material(baked::solid_pierced, baked::solid_pierced_size);
        see = material(baked::solid_soft, baked::solid_soft_size);
        body = material(baked::figure, baked::figure_size);
        billboard = material(baked::sprite, baked::sprite_size);
        stroke = material(baked::line, baked::line_size);
        sheetOf = material(baked::sheet, baked::sheet_size);
        grading = ColorGrading::Builder().toneMapper(&shoulder).quality(ColorGrading::QualityLevel::HIGH).build(engine);

        const uint8_t level[4] = {128, 128, 255, 255}, nothing[4] = {0, 0, 0, 0};
        flat = texture(1, 1, Texture::InternalFormat::RGBA8, false);
        flat->setImage(engine, 0, pixels(level, 4, Texture::Format::RGBA, Texture::Type::UBYTE));
        blank = texture(1, 1, Texture::InternalFormat::SRGB8_A8, false);
        blank->setImage(engine, 0, pixels(nothing, 4, Texture::Format::RGBA, Texture::Type::UBYTE));
        const int order[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
        uint8_t woven[16];
        for (int i = 0; i < 16; i++) { woven[i] = uint8_t(std::lround(order[i] * 255.0 / 16.0)); }
        bayer = texture(4, 4, Texture::InternalFormat::R8, false);
        bayer->setImage(engine, 0, pixels(woven, 16, Texture::Format::R, Texture::Type::UBYTE));

        pool = texture(ROW_TEXELS, POOL_ROWS, Texture::InternalFormat::RGBA32F, false);
        poolRows.assign(size_t(ROW_TEXELS) * POOL_ROWS * 4, 0);
        for (int i = PER_ROW * POOL_ROWS - 1; i >= 0; i--) { poolSpare.push_back(i); }
        poolLow = 0;
        poolHigh = POOL_ROWS - 1;

        const float corners[] = {-0.5f, 0, 0, 0, 0, 0.5f, 0, 0, 1, 0, 0.5f, 1, 0, 1, 1, -0.5f, 1, 0, 0, 1};
        const uint32_t order6[] = {0, 1, 2, 0, 2, 3};
        quadForm.points = VertexBuffer::Builder().vertexCount(4).bufferCount(1)
            .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3, 0, 20)
            .attribute(VertexAttribute::UV0, 0, VertexBuffer::AttributeType::FLOAT2, 12, 20).build(engine);
        quadForm.points->setBufferAt(engine, 0, kept(corners, sizeof(corners)));
        quadForm.corners = IndexBuffer::Builder().indexCount(6).bufferType(IndexBuffer::IndexType::UINT).build(engine);
        quadForm.corners->setBuffer(engine, kept(order6, sizeof(order6)));
        quadForm.count = 6;

        lineLook = stroke->createInstance();
        veiled.push_back(lineLook);
        lineEntity = EntityManager::get().create();

        sun = EntityManager::get().create();
        LightManager::ShadowOptions shade;
        shade.mapSize = SHADOW_MAP;
        shade.stable = true;
        shade.shadowFar = shadeFar;
        LightManager::Builder(LightManager::Type::DIRECTIONAL).color(LinearColor{1.0f, 0.8714f, 0.7157f}).intensity(2.6f)
            .direction(-normalize(float3{0.36f, 0.85f, 0.48f})).castShadows(true).shadowOptions(shade)
            .build(engine, sun);
        stage->addEntity(sun);

        skyCube = Texture::Builder().width(SKY_FACE).height(SKY_FACE).levels(1)
            .sampler(Texture::Sampler::SAMPLER_CUBEMAP).format(Texture::InternalFormat::RGBA16F).build(engine);
        sky = Skybox::Builder().environment(skyCube).build(engine);
        glowCube = Texture::Builder().width(GLOW_FACE).height(GLOW_FACE).levels(GLOW_LEVELS)
            .sampler(Texture::Sampler::SAMPLER_CUBEMAP).format(Texture::InternalFormat::RGBA16F).build(engine);

        main = looking();
        main.view->setShadowingEnabled(true);
        sheetHolder = EntityManager::get().create();
        sheetCamera = engine.createCamera(sheetHolder);
        sheetView = engine.createView();
        sheetView->setScene(page);
        sheetView->setCamera(sheetCamera);
        sheetView->setPostProcessingEnabled(false);
        sheetView->setShadowingEnabled(false);
        fogged();
    }

    Sight looking() {
        Sight l;
        l.holder = EntityManager::get().create();
        l.camera = engine.createCamera(l.holder);
        l.camera->setExposure(1.0f);
        l.view = engine.createView();
        l.view->setScene(stage);
        l.view->setCamera(l.camera);
        l.view->setColorGrading(grading);
        l.view->setAntiAliasing(View::AntiAliasing::NONE);
        l.view->setDithering(View::Dithering::NONE);
        View::MultiSampleAntiAliasingOptions edges;
        edges.enabled = true;
        edges.sampleCount = 4;
        l.view->setMultiSampleAntiAliasingOptions(edges);
        l.view->setShadowType(View::ShadowType::PCF);
        l.sheet = sheetOf->createInstance();
        l.sheet->setParameter("weave", bayer, TextureSampler(TextureSampler::MinFilter::NEAREST,
            TextureSampler::MagFilter::NEAREST, TextureSampler::WrapMode::REPEAT));
        l.corners = VertexBuffer::Builder().vertexCount(4).bufferCount(1)
            .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3, 0, 20)
            .attribute(VertexAttribute::UV0, 0, VertexBuffer::AttributeType::FLOAT2, 12, 20).build(engine);
        l.quad = EntityManager::get().create();
        RenderableManager::Builder(1).geometry(0, RenderableManager::PrimitiveType::TRIANGLES, l.corners,
            quadForm.corners, 0, 6).material(0, l.sheet).culling(false).castShadows(false).receiveShadows(false)
            .build(engine, l.quad);
        return l;
    }

    void unlooked(Sight& l) {
        if (l.staged) { page->remove(l.quad); }
        engine.destroy(l.quad);
        EntityManager::get().destroy(l.quad);
        engine.destroy(l.sheet);
        engine.destroy(l.corners);
        engine.destroy(l.view);
        if (l.target) { spent.push_back(Spent{l.target, l.colour, 3}); }
        engine.destroyCameraComponent(l.holder);
        EntityManager::get().destroy(l.holder);
        l = Sight();
    }

    void heavens(const std::string& hex) {
        if (skyHex == hex) { return; }
        skyHex = hex;
        Colour c = colourOf(hex);
        float3 mid{c.r, c.g, c.b};
        float3 hz = lerp3(mid, float3(1.0f), hazeAmount(c));
        float3 stops[4] = {quantised(mid * 0.66f), quantised(mid), quantised(hz), quantised(hz * 0.82f)};
        const float at[4] = {0, 0.42f, 0.52f, 1};
        float3 band[256];
        for (int i = 0; i < 256; i++) {
            band[i] = unshouldered(lightOf(banded(stops, at, 4, (float(i) + 0.5f) / 256.0f)));
        }
        fill(skyCube, 0, SKY_FACE, [&](float3 d) {
            float v = std::acos(std::max(-1.0f, std::min(1.0f, d.y))) / PI_F * 256.0f - 0.5f;
            int i = std::max(0, std::min(254, int(std::floor(v))));
            float t = std::max(0.0f, std::min(1.0f, v - float(i)));
            return lerp3(band[i], band[i + 1], t);
        });
        haze = unshouldered(lightOf(quantised(hz)));
        fogged();
    }

    template <typename F> void fill(Texture* cube, int level, int side, F colour) {
        std::vector<float> data(size_t(side) * side * 6 * 4);
        for (int face = 0; face < 6; face++) {
            for (int y = 0; y < side; y++) {
                for (int x = 0; x < side; x++) {
                    float s = 2 * (float(x) + 0.5f) / float(side) - 1, t = 2 * (float(y) + 0.5f) / float(side) - 1;
                    float3 d;
                    switch (face) {
                    case 0: d = float3{1, -t, -s}; break;
                    case 1: d = float3{-1, -t, s}; break;
                    case 2: d = float3{s, 1, t}; break;
                    case 3: d = float3{s, -1, -t}; break;
                    case 4: d = float3{s, -t, 1}; break;
                    default: d = float3{-s, -t, -1}; break;
                    }
                    float3 c = colour(normalize(d));
                    float* out = &data[((size_t(face) * side + y) * side + x) * 4];
                    out[0] = c.r;
                    out[1] = c.g;
                    out[2] = c.b;
                    out[3] = 1;
                }
            }
        }
        cube->setImage(engine, size_t(level), 0, 0, 0, uint32_t(side), uint32_t(side), 6,
            pixels(data.data(), data.size() * 4, Texture::Format::RGBA, Texture::Type::FLOAT));
    }

    // Below the horizon is the ground; its brightness barely follows the sky, or night would be dark twice.
    void lit(const std::string& hex) {
        auto now = std::chrono::steady_clock::now();
        if (hex == glowHex || (glowMade && now - glowAt < std::chrono::milliseconds(500))) { return; }
        glowHex = hex;
        glowAt = now;
        Colour c = colourOf(hex);
        float3 mid{c.r, c.g, c.b};
        float3 hz = lerp3(mid, float3(1.0f), hazeAmount(c));
        float3 high = mid * 0.66f;
        float3 dirt = lerp3(hz, float3{0.3f, 0.25f, 0.18f}, 0.65f) * 0.45f;
        float level = 0.45f * (0.3f + 0.7f * std::min(1.0f, luma(mid.r, mid.g, mid.b) / 0.5f));
        float k = level / std::max(0.002f, luma(hz.r, hz.g, hz.b));
        float3 tones[3] = {high, hz, dirt};
        for (auto& t : tones) {
            t *= k;
            float grey = luma(t.r, t.g, t.b);
            t = lerp3(t, float3(grey), 0.5f);
            float top = std::max(t.r, std::max(t.g, t.b));
            if (top > 1) { t *= 1 / top; }
            t = quantised(t);
        }
        float3 stops[4] = {tones[0], tones[1], tones[2], tones[2]};
        const float at[4] = {0, 0.46f, 0.54f, 1};
        const int steps = 64;
        std::vector<float3> band(steps);
        for (int i = 0; i < steps; i++) { band[size_t(i)] = lightOf(banded(stops, at, 4, (float(i) + 0.5f) / steps)); }
        auto from = [&](float y) {
            float v = std::acos(std::max(-1.0f, std::min(1.0f, y))) / PI_F * steps - 0.5f;
            int i = std::max(0, std::min(steps - 2, int(std::floor(v))));
            float t = std::max(0.0f, std::min(1.0f, v - float(i)));
            return lerp3(band[size_t(i)], band[size_t(i) + 1], t);
        };

        for (int lod = 0; lod < GLOW_LEVELS; lod++) {
            float mix = float(lod) / float(GLOW_LEVELS - 1);
            float rough = 1 - std::sqrt(1 - mix);
            float alpha = std::max(rough * rough, 0.001f);
            const int heights = 48, taps = 96;
            std::vector<float3> blurred(heights);
            for (int h = 0; h < heights; h++) {
                float y = 1 - 2 * (float(h) + 0.5f) / heights;
                float3 n{std::sqrt(std::max(0.0f, 1 - y * y)), y, 0};
                float3 side = normalize(cross(std::fabs(y) < 0.99f ? float3{0, 1, 0} : float3{1, 0, 0}, n));
                float3 up = cross(n, side);
                float3 sum{0, 0, 0};
                float weight = 0;
                for (int i = 0; i < taps; i++) {
                    float u = (float(i) + 0.5f) / taps;
                    uint32_t bits = uint32_t(i);
                    bits = (bits << 16) | (bits >> 16);
                    bits = ((bits & 0x55555555u) << 1) | ((bits & 0xAAAAAAAAu) >> 1);
                    bits = ((bits & 0x33333333u) << 2) | ((bits & 0xCCCCCCCCu) >> 2);
                    bits = ((bits & 0x0F0F0F0Fu) << 4) | ((bits & 0xF0F0F0F0u) >> 4);
                    bits = ((bits & 0x00FF00FFu) << 8) | ((bits & 0xFF00FF00u) >> 8);
                    float v = float(bits) * 2.3283064365386963e-10f;
                    float phi = 2 * PI_F * v;
                    float cosT = std::sqrt((1 - u) / (1 + (alpha * alpha - 1) * u));
                    float sinT = std::sqrt(std::max(0.0f, 1 - cosT * cosT));
                    float3 half = side * (sinT * std::cos(phi)) + up * (sinT * std::sin(phi)) + n * cosT;
                    float3 l = half * (2 * dot(n, half)) - n;
                    float nl = dot(n, l);
                    if (nl <= 0) { continue; }
                    sum += from(l.y) * nl;
                    weight += nl;
                }
                blurred[size_t(h)] = weight > 0 ? sum * (1 / weight) : from(y);
            }
            fill(glowCube, lod, GLOW_FACE >> lod, [&](float3 d) {
                float v = (1 - d.y) / 2 * heights - 0.5f;
                int i = std::max(0, std::min(heights - 2, int(std::floor(v))));
                float t = std::max(0.0f, std::min(1.0f, v - float(i)));
                return lerp3(blurred[size_t(i)], blurred[size_t(i) + 1], t);
            });
        }

        float3 sh[9];
        for (auto& s : sh) { s = float3(0.0f); }
        const int rings = 64, round = 16;
        for (int a = 0; a < rings; a++) {
            float theta = (float(a) + 0.5f) / rings * PI_F;
            float y = std::cos(theta), ring = std::sin(theta);
            float3 colour = from(y);
            float area = ring * (PI_F / rings) * (2 * PI_F / round);
            for (int b = 0; b < round; b++) {
                float phi = (float(b) + 0.5f) / round * 2 * PI_F;
                float x = ring * std::cos(phi), z = ring * std::sin(phi);
                const float basis[9] = {0.282095f, 0.488603f * y, 0.488603f * z, 0.488603f * x, 1.092548f * x * y,
                    1.092548f * y * z, 0.315392f * (3 * z * z - 1), 1.092548f * x * z, 0.546274f * (x * x - y * y)};
                for (int k = 0; k < 9; k++) { sh[k] += colour * (basis[k] * area); }
            }
        }
        IndirectLight* next = IndirectLight::Builder().reflections(glowCube).radiance(3, sh).intensity(1.0f)
            .build(engine);
        stage->setIndirectLight(next);
        if (glow) { engine.destroy(glow); }
        glow = next;
        glowMade = true;
    }

    void sunned(const float at[2], float far) {
        sunAt[0] = at[0];
        sunAt[1] = at[1];
        shadeFar = far;
        sunSet = true;
        float3 sunward = normalize(float3{0.36f, 0.85f, 0.48f});
        float3 colour{1.0f, 0.8714f, 0.7157f};
        float strength = 2.6f;
        if (at[1] > -10) {
            float high = std::max(0.05f, std::min(1.55f, at[1]));
            sunward = float3{-std::sin(at[0]) * std::cos(high), std::sin(high), -std::cos(at[0]) * std::cos(high)};
            float low = std::max(0.0f, std::min(1.0f, 1 - std::sin(high) / 0.5f));
            colour = lerp3(colour, float3{1.0f, 0.4564f, 0.1559f}, low * 0.8f);
            strength = 2.6f * (1 - 0.35f * low);
        }
        auto& lights = engine.getLightManager();
        auto light = lights.getInstance(sun);
        lights.setDirection(light, -sunward);
        lights.setColor(light, LinearColor{colour.r, colour.g, colour.b});
        lights.setIntensity(light, strength);
        LightManager::ShadowOptions shade;
        shade.mapSize = SHADOW_MAP;
        shade.stable = true;
        shade.shadowFar = far;
        lights.setShadowOptions(light, shade);
    }

    void fogged() {
        for (MaterialInstance* m : veiled) { veil(m); }
    }

    void veil(MaterialInstance* m) {
        m->setParameter("fog", float4{fogNear, fogFar, fogOn, 0});
        m->setParameter("haze", float4{haze.r, haze.g, haze.b, 1});
    }

    void unveiled(MaterialInstance* m) {
        veiled.erase(std::remove(veiled.begin(), veiled.end(), m), veiled.end());
    }

    const Picture* photo(const std::string& name) {
        auto found = photos.find(name);
        if (found != photos.end()) { return found->second.empty() ? nullptr : &found->second; }
        if (!photoAsked[name]) {
            photoAsked[name] = true;
            host.wantPicture("textures/" + name + ".jpg");
        }
        return nullptr;
    }

    static std::string lower(std::string s) {
        for (auto& c : s) { c = char(std::tolower(static_cast<unsigned char>(c))); }
        return s;
    }

    Coat& skinOf(const std::string& finish) {
        auto found = skins.find(finish);
        if (found != skins.end()) { return found->second; }
        Coat& skin = skins[finish];
        skin.finish = finish;
        skin.grain = texture(256, 256, Texture::InternalFormat::SRGB8_A8, true, "grain");
        if (bumped(finish)) { skin.relief = texture(256, 256, Texture::InternalFormat::RGBA8, true, "relief"); }
        woven(skin);
        return skin;
    }

    void woven(Coat& skin) {
        std::string name = lower(skin.finish);
        hive::Skin made = weave(skin.finish, photo(name), skin.relief ? photo(name + "-normal") : nullptr);
        skin.grain->setImage(engine, 0, pixels(made.grain.data(), made.grain.size(), Texture::Format::RGBA,
            Texture::Type::UBYTE));
        skin.grain->generateMipmaps(engine);
        if (skin.relief && !made.relief.empty()) {
            skin.relief->setImage(engine, 0, pixels(made.relief.data(), made.relief.size(), Texture::Format::RGBA,
                Texture::Type::UBYTE));
            skin.relief->generateMipmaps(engine);
        }
    }

    MaterialInstance* dressed(Material* from, const std::string& finish, Texture* things, bool land) {
        Coat& skin = skinOf(finish);
        hive::Look look = lookOf(finish);
        MaterialInstance* m = from->createInstance();
        m->setParameter("things", things, exact());
        m->setParameter("grain", skin.grain, tiled());
        m->setParameter("relief", skin.relief ? skin.relief : flat, tiled());
        m->setParameter("look", float4{look.rough, look.metal, look.relief, perTile(finish)});
        bool own = !land && (finish == "Panes" || finish == "Kerb" || finish == "Crowd");
        m->setParameter("flags", float4{own ? 1.0f : 0.0f, (!land && finish == "Panes") ? 1.0f : 0.0f,
            broad(finish) ? 1.0f : 0.0f, skin.relief ? 1.0f : 0.0f});
        m->setParameter("base", 0.0f);
        if (from != opaque) {
            bool holes = finish == "Mesh";
            m->setDoubleSided(holes);
            m->setCullingMode(holes ? MaterialInstance::CullingMode::NONE : MaterialInstance::CullingMode::BACK);
            if (from == pierced) { m->setMaskThreshold(0.5f); }
        }
        veil(m);
        veiled.push_back(m);
        return m;
    }

    Batch* batchOf(const std::string& form, const std::string& finish) {
        auto& all = batches[form + "|" + finish];
        for (Batch* b : all) {
            if (int(b->seats.size()) < MOST_SEATS) { return b; }
        }
        Batch* b = new Batch();
        b->form = &unit(form);
        b->cast = form != "ground";
        b->entity = EntityManager::get().create();
        b->look = dressed(finish == "Mesh" ? pierced : opaque, finish, flat, false);
        grow(*b, PER_ROW);
        RenderableManager::Builder(1).geometry(0, RenderableManager::PrimitiveType::TRIANGLES, b->form->points,
            b->form->corners, 0, b->form->count).material(0, b->look).culling(false).castShadows(b->cast)
            .receiveShadows(true).instances(1).boundingBox({{0, 0, 0}, {1, 1, 1}}).build(engine, b->entity);
        all.push_back(b);
        return b;
    }

    void grow(Batch& b, int room) {
        room = std::min(room, MOST_SEATS + PER_ROW - 1) / PER_ROW * PER_ROW;
        Texture* next = texture(ROW_TEXELS, room / PER_ROW, Texture::InternalFormat::RGBA32F, false, "things");
        b.rows.resize(size_t(room) * 16, 0);
        if (b.things) { engine.destroy(b.things); }
        b.things = next;
        b.room = room;
        b.look->setParameter("things", next, exact());
        b.low = 0;
        b.high = room / PER_ROW - 1;
    }

    void seat(Thing* o) {
        if (o->index >= 0) { return; }
        Batch& b = *o->batch;
        if (int(b.seats.size()) == b.room) { grow(b, b.room * 2); }
        o->index = int(b.seats.size());
        b.seats.push_back(o);
        o->tint.clear();
        counted(b);
    }

    void unseat(Thing* o) {
        Batch& b = *o->batch;
        int at = o->index;
        if (at < 0) { return; }
        int last = int(b.seats.size()) - 1;
        if (at != last) {
            memcpy(&b.rows[size_t(at) * 16], &b.rows[size_t(last) * 16], 64);
            touched(b, at);
            b.seats[size_t(at)] = b.seats[size_t(last)];
            b.seats[size_t(at)]->index = at;
        }
        b.seats.pop_back();
        o->index = -1;
        counted(b);
    }

    void touched(Batch& b, int at) {
        b.low = std::min(b.low, at / PER_ROW);
        b.high = std::max(b.high, at / PER_ROW);
    }

    void counted(Batch& b) {
        bool any = !b.seats.empty();
        if (any) {
            auto& solids = engine.getRenderableManager();
            solids.setInstanceCount(solids.getInstance(b.entity), b.seats.size());
        }
        if (any != b.shown) {
            if (any) { stage->addEntity(b.entity); }
            else { stage->remove(b.entity); }
            b.shown = any;
        }
    }

    void place(Thing* o, const Record& s) {
        if (o->index < 0) { seat(o); }
        Batch& b = *o->batch;
        float* row = &b.rows[size_t(o->index) * 16];
        float size[3];
        stretch(s, size);
        placed(row, s.p, s.turned ? turned(s.r[0], s.r[1], s.r[2]) : turned(0, 0, 0), size);
        if (o->tint != s.c || o->tint.empty()) {
            Colour c = colourOf(s.c);
            row[12] = c.r;
            row[13] = c.g;
            row[14] = c.b;
            row[15] = 1;
            o->tint = s.c;
        }
        touched(b, o->index);
    }

    // Filament refuses a shadow caster or catcher with no bounds.
    void bounded(Entity entity, const std::vector<float>& rows, size_t count) {
        if (count == 0) { return; }
        float3 low(1e30f), high(-1e30f);
        for (size_t i = 0; i < count; i++) {
            const float* r = &rows[i * 16];
            float reach = std::sqrt(r[0] * r[0] + r[4] * r[4] + r[8] * r[8]) +
                std::sqrt(r[1] * r[1] + r[5] * r[5] + r[9] * r[9]) +
                std::sqrt(r[2] * r[2] + r[6] * r[6] + r[10] * r[10]);
            float3 at{r[3], r[7], r[11]};
            low = min(low, at - float3(reach));
            high = max(high, at + float3(reach));
        }
        auto& solids = engine.getRenderableManager();
        solids.setAxisAlignedBoundingBox(solids.getInstance(entity), filament::Box{(low + high) * 0.5f, (high - low) * 0.5f});
    }

    void upload(Texture* things, std::vector<float>& rows, int& low, int& high) {
        if (high < low) { return; }
        size_t each = size_t(ROW_TEXELS) * 4;
        things->setImage(engine, 0, 0, uint32_t(low), uint32_t(ROW_TEXELS), uint32_t(high - low + 1),
            pixels(&rows[size_t(low) * each], size_t(high - low + 1) * each * 4, Texture::Format::RGBA,
                Texture::Type::FLOAT));
        low = 1 << 30;
        high = -1;
    }

    int lent() {
        if (poolSpare.empty()) { return -1; }
        int slot = poolSpare.back();
        poolSpare.pop_back();
        return slot;
    }

    float* pooled(int slot) {
        poolLow = std::min(poolLow, slot / PER_ROW);
        poolHigh = std::max(poolHigh, slot / PER_ROW);
        return &poolRows[size_t(slot) * 16];
    }

    void alone(Thing* o, const Form& form, Material* from, const std::string& finish, bool cast, bool land) {
        o->slot = lent();
        o->look = dressed(from, finish, pool, land);
        o->look->setParameter("base", float(std::max(0, o->slot)));
        o->entity = EntityManager::get().create();
        o->standing = true;
        RenderableManager::Builder(1).geometry(0, RenderableManager::PrimitiveType::TRIANGLES, form.points,
            form.corners, 0, form.count).material(0, o->look).culling(false).castShadows(cast).receiveShadows(true)
            .instances(1).boundingBox({{0, 0, 0}, {1, 1, 1}}).build(engine, o->entity);
        engine.getTransformManager().create(o->entity);
    }

    void show(Thing* o, bool on) {
        if (!o->standing || o->staged == on) { return; }
        if (on) { stage->addEntity(o->entity); }
        else { stage->remove(o->entity); }
        o->staged = on;
    }

    Crowd* crowdOf(const std::string& path) {
        auto found = crowds.find(path);
        if (found != crowds.end()) { return found->second; }
        Crowd* c = new Crowd();
        c->path = path;
        crowds[path] = c;
        host.wantFile(path);
        return c;
    }

    void muster(Crowd& c) {
        Model& m = c.model;
        size_t n = m.place.size() / 3;
        const int wide = 23;
        std::vector<float> data(n * wide);
        for (size_t i = 0; i < n; i++) {
            float* v = &data[i * wide];
            memcpy(v, &m.place[i * 3], 12);
            c.reach = std::max(c.reach, 1.5f * std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
            const float any[4] = {0, 0, 0, 1};
            quatf q = framed(&m.facing[i * 3], any);
            v[3] = q.x;
            v[4] = q.y;
            v[5] = q.z;
            v[6] = q.w;
            v[7] = float(m.tint[i * 3]) / 255.0f;
            v[8] = float(m.tint[i * 3 + 1]) / 255.0f;
            v[9] = float(m.tint[i * 3 + 2]) / 255.0f;
            v[10] = 1;
            memcpy(v + 11, &m.bones[i * 4], 16);
            memcpy(v + 15, &m.weights[i * 4], 16);
            v[19] = float(m.part[i]);
            v[20] = v[21] = v[22] = 0;
        }
        const uint8_t stride = 92;
        c.form.points = VertexBuffer::Builder().vertexCount(uint32_t(n)).bufferCount(1)
            .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3, 0, stride)
            .attribute(VertexAttribute::TANGENTS, 0, VertexBuffer::AttributeType::FLOAT4, 12, stride)
            .attribute(VertexAttribute::COLOR, 0, VertexBuffer::AttributeType::FLOAT4, 28, stride)
            .attribute(VertexAttribute::CUSTOM0, 0, VertexBuffer::AttributeType::FLOAT4, 44, stride)
            .attribute(VertexAttribute::CUSTOM1, 0, VertexBuffer::AttributeType::FLOAT4, 60, stride)
            .attribute(VertexAttribute::CUSTOM2, 0, VertexBuffer::AttributeType::FLOAT4, 76, stride)
            .build(engine);
        c.form.points->setBufferAt(engine, 0, kept(data.data(), data.size() * 4));
        c.form.corners = IndexBuffer::Builder().indexCount(uint32_t(m.index.size()))
            .bufferType(IndexBuffer::IndexType::UINT).build(engine);
        c.form.corners->setBuffer(engine, kept(m.index.data(), m.index.size() * 4));
        c.form.count = uint32_t(m.index.size());
        c.wide = 4 + int(m.joints.size()) * 4;
        c.look = body->createInstance();
        c.look->setParameter("base", 0.0f);
        veil(c.look);
        veiled.push_back(c.look);
        c.entity = EntityManager::get().create();
        quarters(c, std::max(16, int(c.seats.size())));
        RenderableManager::Builder(1).geometry(0, RenderableManager::PrimitiveType::TRIANGLES, c.form.points,
            c.form.corners, 0, c.form.count).material(0, c.look).culling(false).castShadows(true)
            .receiveShadows(true).instances(1).boundingBox({{0, 0, 0}, {1, 1, 1}}).build(engine, c.entity);
        for (Thing* o : c.seats) { stand(o); }
        mustered(c);
    }

    void quarters(Crowd& c, int many) {
        many = std::min(many, 32767);
        Texture* bones = texture(c.wide, many, Texture::InternalFormat::RGBA32F, false);
        Texture* paints = texture(PARTS, many, Texture::InternalFormat::RGBA32F, false);
        c.boneRows.resize(size_t(many) * c.wide * 4, 0);
        c.paintRows.resize(size_t(many) * PARTS * 4, 0);
        if (c.bones) { engine.destroy(c.bones); }
        if (c.paints) { engine.destroy(c.paints); }
        c.bones = bones;
        c.paints = paints;
        c.room = many;
        c.look->setParameter("bones", bones, exact());
        c.look->setParameter("paints", paints, exact());
        c.low = 0;
        c.high = many - 1;
    }

    void mustered(Crowd& c) {
        if (!c.model.ready) { return; }
        bool any = !c.seats.empty();
        if (any) {
            auto& solids = engine.getRenderableManager();
            solids.setInstanceCount(solids.getInstance(c.entity), c.seats.size());
        }
        if (any != c.shown) {
            if (any) { stage->addEntity(c.entity); }
            else { stage->remove(c.entity); }
            c.shown = any;
        }
    }

    void enlist(Thing* o) {
        if (o->index >= 0) { return; }
        Crowd& c = *o->crowd;
        o->index = int(c.seats.size());
        c.seats.push_back(o);
        if (c.model.ready && int(c.seats.size()) > c.room) {
            quarters(c, c.room * 2);
            for (Thing* seated : c.seats) { stand(seated); }
        }
        mustered(c);
    }

    void discharge(Thing* o) {
        Crowd& c = *o->crowd;
        int at = o->index;
        if (at < 0) { return; }
        int last = int(c.seats.size()) - 1;
        Thing* end = c.seats[size_t(last)];
        c.seats.pop_back();
        o->index = -1;
        if (at != last) {
            c.seats[size_t(at)] = end;
            end->index = at;
            stand(end);
        }
        mustered(c);
    }

    void stand(Thing* o) {
        Crowd& c = *o->crowd;
        int at = o->index;
        if (!c.model.ready || at < 0 || at >= c.room) { return; }
        Model& m = c.model;
        float* row = &c.boneRows[size_t(at) * c.wide * 4];
        placed(row, o->at, turned(o->turn[0], o->turn[1], o->turn[2]), o->size);
        std::vector<mat4f> stood(m.joints.size());
        for (int k : m.order) {
            const Joint& j = m.joints[size_t(k)];
            quatf turn{j.r[3], j.r[0], j.r[1], j.r[2]};
            if (size_t(k) * 3 + 2 < o->pose.size()) {
                turn = turn * spun(o->pose[size_t(k) * 3], o->pose[size_t(k) * 3 + 1], o->pose[size_t(k) * 3 + 2]);
            }
            mat4f local = composed(j.t, turn, j.s);
            stood[size_t(k)] = j.parent >= 0 ? stood[size_t(j.parent)] * local : local;
            mat4f inverse;
            memcpy(&inverse, &m.inverses[size_t(k) * 16], 64);
            mat4f out = stood[size_t(k)] * inverse;
            memcpy(row + 16 + size_t(k) * 16, &out, 64);
        }
        float* tints = &c.paintRows[size_t(at) * PARTS * 4];
        for (int k = 0; k < PARTS; k++) {
            if (size_t(k) < o->paints.size() && !o->paints[size_t(k)].empty()) {
                Colour tone = colourOf(o->paints[size_t(k)]);
                tints[k * 4] = tone.r;
                tints[k * 4 + 1] = tone.g;
                tints[k * 4 + 2] = tone.b;
                tints[k * 4 + 3] = tone.a;
            } else {
                memcpy(tints + k * 4, m.tints + k * 4, 16);
            }
        }
        c.low = std::min(c.low, at);
        c.high = std::max(c.high, at);
    }

    void arrayed(Thing* o, const Record& s) {
        if (o->index < 0) { enlist(o); }
        for (int k = 0; k < 3; k++) {
            o->at[k] = s.p[k];
            o->turn[k] = s.turned ? s.r[k] : 0;
            o->size[k] = s.z[k];
        }
        o->pose = s.d;
        o->paints = s.t;
        stand(o);
    }

    void lie(Thing* o, const Record& s) {
        Land& land = *o->land;
        if (s.x.empty() || land.asked == s.x) { return; }
        land.asked = s.x;
        auto held = grounds.find(s.x);
        if (held != grounds.end()) {
            laid(o, held->second.data(), held->second.size());
            return;
        }
        host.wantTerrain(s.x);
    }

    void laid(Thing* o, const uint8_t* data, size_t size) {
        Land& land = *o->land;
        if (size < 12) { return; }
        Reader r(data, size);
        int wide = int(r.u32()), rows = int(r.u32());
        float cell = r.f32();
        size_t count = size_t(wide) * size_t(rows);
        if (wide < 2 || rows < 2 || size < 12 + count * 7) { return; }
        std::vector<float> high(count);
        memcpy(high.data(), data + 12, count * 4);
        const uint8_t* tint = data + 12 + count * 4;
        float halfX = float(wide - 1) * cell / 2, halfZ = float(rows - 1) * cell / 2;
        const int each = 25;
        std::vector<float> points(count * each);
        for (int j = 0; j < rows; j++) {
            for (int i = 0; i < wide; i++) {
                size_t k = size_t(j) * wide + i;
                float west = high[k - (i > 0 ? 1 : 0)], east = high[k + (i < wide - 1 ? 1 : 0)];
                float north = high[k - (j > 0 ? wide : 0)], south = high[k + (j < rows - 1 ? wide : 0)];
                float sx = (east - west) / (float((i > 0 && i < wide - 1) ? 2 : 1) * cell);
                float sz = (south - north) / (float((j > 0 && j < rows - 1) ? 2 : 1) * cell);
                float len = std::sqrt(sx * sx + 1 + sz * sz);
                const float facing[3] = {-sx / len, 1 / len, -sz / len}, along[4] = {1, 0, 0, -1};
                float* v = &points[k * each];
                v[0] = float(i) * cell - halfX;
                v[1] = high[k];
                v[2] = float(j) * cell - halfZ;
                land.reach = std::max(land.reach, std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
                quatf q = framed(facing, along);
                v[3] = q.x;
                v[4] = q.y;
                v[5] = q.z;
                v[6] = q.w;
                v[7] = float(i) / float(wide - 1);
                v[8] = float(j) / float(rows - 1);
                v[9] = decoded(float(tint[k * 3]) / 255.0f);
                v[10] = decoded(float(tint[k * 3 + 1]) / 255.0f);
                v[11] = decoded(float(tint[k * 3 + 2]) / 255.0f);
                v[12] = 1;
                v[13] = halfX * 2;
                v[19] = halfZ * 2;
                v[21] = 1;
                v[24] = -1;
            }
        }
        auto& solids = engine.getRenderableManager();
        if (land.wide != wide || land.rows != rows) {
            std::vector<uint32_t> index;
            index.reserve(size_t(wide - 1) * (rows - 1) * 6);
            for (int j = 0; j < rows - 1; j++) {
                for (int i = 0; i < wide - 1; i++) {
                    uint32_t k = uint32_t(j * wide + i);
                    index.insert(index.end(), {k, k + uint32_t(wide), k + 1, k + 1, k + uint32_t(wide),
                        k + uint32_t(wide) + 1});
                }
            }
            Form old = land.form;
            land.form.points = solidPoints(uint32_t(count));
            land.form.corners = IndexBuffer::Builder().indexCount(uint32_t(index.size()))
                .bufferType(IndexBuffer::IndexType::UINT).build(engine);
            land.form.corners->setBuffer(engine, kept(index.data(), index.size() * 4));
            land.form.count = uint32_t(index.size());
            solids.setGeometryAt(solids.getInstance(o->entity), 0, RenderableManager::PrimitiveType::TRIANGLES,
                land.form.points, land.form.corners, 0, land.form.count);
            if (old.points) { engine.destroy(old.points); }
            if (old.corners) { engine.destroy(old.corners); }
            land.wide = wide;
            land.rows = rows;
        }
        land.cell = cell;
        land.laid = land.asked;
        land.form.points->setBufferAt(engine, 0, kept(points.data(), points.size() * 4));
        show(o, o->visible);
    }

    Shared* signOf(const std::string& words, const std::string& colour) {
        std::string key = words + "|" + colour;
        auto found = signs.find(key);
        if (found != signs.end()) { return found->second; }
        Shared* s = new Shared();
        signs[key] = s;
        host.wantLabel(words, colour);
        return s;
    }

    Shared* picOf(const std::string& path) {
        auto found = pics.find(path);
        if (found != pics.end()) { return found->second; }
        Shared* s = new Shared();
        pics[path] = s;
        host.wantPicture(path);
        return s;
    }

    void upright(Thing* o) {
        o->look = billboard->createInstance();
        veil(o->look);
        veiled.push_back(o->look);
        o->entity = EntityManager::get().create();
        o->standing = true;
        RenderableManager::Builder(1).geometry(0, RenderableManager::PrimitiveType::TRIANGLES, quadForm.points,
            quadForm.corners, 0, 6).material(0, o->look).culling(false).castShadows(false).receiveShadows(false)
            .boundingBox({{0, 0, 0}, {1, 1, 1}}).build(engine, o->entity);
        engine.getTransformManager().create(o->entity);
        o->shared->users.push_back(o);
        worn(o);
    }

    void worn(Thing* o) {
        Shared& s = *o->shared;
        Texture* t = s.texture ? s.texture : blank;
        if (o->kind == LABEL) {
            o->look->setParameter("picture", t, smooth());
            o->look->setParameter("shape", float4{0.42f * s.aspect, 0.42f, 0.5f, 0.0f});
            o->look->setParameter("tint", float4{1, 1, 1, 1});
        } else {
            o->look->setParameter("picture", t, o->soft ? smooth() : exact());
            o->look->setParameter("shape", float4{o->dims[0] != 0 ? o->dims[0] : 1.0f,
                o->dims[1] != 0 ? o->dims[1] : 1.0f, 0.0f, o->soft ? 0.0f : 0.4f});
        }
    }

    void ruled() {
        if (!linesMoved) { return; }
        linesMoved = false;
        std::vector<Thing*> drawn;
        for (Thing* o : lines) {
            if (o->visible) { drawn.push_back(o); }
        }
        auto& solids = engine.getRenderableManager();
        if (int(drawn.size()) > lineRoom) {
            int room = std::max(16, int(drawn.size()) * 2);
            Form old = lineForm;
            lineForm.points = VertexBuffer::Builder().vertexCount(uint32_t(room) * 2).bufferCount(1)
                .attribute(VertexAttribute::POSITION, 0, VertexBuffer::AttributeType::FLOAT3, 0, 28)
                .attribute(VertexAttribute::COLOR, 0, VertexBuffer::AttributeType::FLOAT4, 12, 28).build(engine);
            std::vector<uint32_t> index(size_t(room) * 2);
            for (size_t i = 0; i < index.size(); i++) { index[i] = uint32_t(i); }
            lineForm.corners = IndexBuffer::Builder().indexCount(uint32_t(index.size()))
                .bufferType(IndexBuffer::IndexType::UINT).build(engine);
            lineForm.corners->setBuffer(engine, kept(index.data(), index.size() * 4));
            if (lineRoom > 0) {
                if (linesShown) { stage->remove(lineEntity); }
                linesShown = false;
                engine.destroy(lineEntity);
                engine.destroy(old.points);
                engine.destroy(old.corners);
            }
            RenderableManager::Builder(1).geometry(0, RenderableManager::PrimitiveType::LINES, lineForm.points,
                lineForm.corners, 0, 2).material(0, lineLook).culling(false).castShadows(false).receiveShadows(false)
                .priority(6).build(engine, lineEntity);
            lineRoom = room;
        }
        if (lineRoom == 0) { return; }
        std::vector<float> data(size_t(lineRoom) * 14, 0);
        for (size_t i = 0; i < drawn.size(); i++) {
            Thing* o = drawn[i];
            for (int end = 0; end < 2; end++) {
                float* v = &data[i * 14 + size_t(end) * 7];
                memcpy(v, o->ends + end * 3, 12);
                v[3] = o->stroke.r;
                v[4] = o->stroke.g;
                v[5] = o->stroke.b;
                v[6] = o->stroke.a;
            }
        }
        lineForm.points->setBufferAt(engine, 0, kept(data.data(), data.size() * 4));
        bool any = !drawn.empty();
        if (any) {
            solids.setGeometryAt(solids.getInstance(lineEntity), 0, RenderableManager::PrimitiveType::LINES,
                lineForm.points, lineForm.corners, 0, drawn.size() * 2);
        }
        if (any != linesShown) {
            if (any) { stage->addEntity(lineEntity); }
            else { stage->remove(lineEntity); }
            linesShown = any;
        }
    }

    std::string keyOf(const Record& s) {
        return formOf(s) + "|" + finishOf(s) + (colourOf(s.c).a < 1 ? "|see" : "");
    }

    bool fits(Thing* o, const Record& s) {
        if (!o || o->kind != s.kind) { return false; }
        switch (s.kind) {
        case LINE:
        case TERRAIN:
            return true;
        case LABEL:
            return o->words == s.x && o->tint == s.c;
        case SPRITE:
            return o->words == s.x && o->dims[0] == (s.d.size() > 0 ? s.d[0] : 0) &&
                o->dims[1] == (s.d.size() > 1 ? s.d[1] : 0) && o->soft == (colourOf(s.c).a < 1);
        case FIGURE:
            return o->words == s.x;
        default:
            return o->key == keyOf(s);
        }
    }

    Thing* build(const Record& s) {
        Thing* o = new Thing();
        o->kind = s.kind;
        o->key = keyOf(s);
        o->words = s.x;
        std::string finish = finishOf(s);
        switch (s.kind) {
        case LINE:
            lines.push_back(o);
            break;
        case LABEL:
            o->tint = s.c;
            o->shared = signOf(s.x, s.c);
            upright(o);
            break;
        case SPRITE:
            o->soft = colourOf(s.c).a < 1;
            o->dims[0] = s.d.size() > 0 ? s.d[0] : 0;
            o->dims[1] = s.d.size() > 1 ? s.d[1] : 0;
            o->shared = picOf(s.x);
            upright(o);
            break;
        case FIGURE:
            o->crowd = crowdOf(s.x);
            break;
        case TERRAIN:
            o->land = new Land();
            o->finish = finish;
            alone(o, quadFormed(), opaque, finish, true, true);
            break;
        default:
            if (colourOf(s.c).a >= 1) {
                o->batch = batchOf(formOf(s), finish);
            } else {
                o->soft = true;
                alone(o, unit(formOf(s)), see, finish, false, false);
            }
        }
        return o;
    }

    // The ground borrows a shape and stays off the stage until its heights arrive.
    const Form& quadFormed() { return unit("ground"); }

    void put(Thing* o, const Record& s) {
        if (o->batch) {
            place(o, s);
            return;
        }
        if (o->crowd) {
            arrayed(o, s);
            return;
        }
        if (s.kind == LINE) {
            for (size_t i = 0; i < 6; i++) { o->ends[i] = i < s.d.size() ? s.d[i] : 0; }
            o->stroke = colourOf(s.c);
            linesMoved = true;
            return;
        }
        auto& places = engine.getTransformManager();
        if (s.kind == LABEL || s.kind == SPRITE) {
            places.setTransform(places.getInstance(o->entity), mat4f::translation(float3{s.p[0], s.p[1], s.p[2]}));
            if (s.kind == SPRITE && (o->tint != s.c || o->tint.empty())) {
                Colour c = colourOf(s.c);
                o->look->setParameter("tint", float4{c.r, c.g, c.b, c.a});
                o->tint = s.c;
            }
            show(o, o->visible);
            return;
        }
        Turn t = s.turned ? turned(s.r[0], s.r[1], s.r[2]) : turned(0, 0, 0);
        if (o->slot < 0) { return; }
        float* row = pooled(o->slot);
        if (s.kind == TERRAIN) {
            const float one[3] = {1, 1, 1};
            placed(row, s.p, t, one);
            Colour c = colourOf(s.c);
            row[12] = c.r;
            row[13] = c.g;
            row[14] = c.b;
            row[15] = 1;
            lie(o, s);
            auto& solids = engine.getRenderableManager();
            solids.setAxisAlignedBoundingBox(solids.getInstance(o->entity),
                filament::Box{float3{s.p[0], s.p[1], s.p[2]}, float3(o->land->reach)});
            show(o, o->visible && !o->land->laid.empty());
            return;
        }
        // Sorted against the rest by where it stands, so that is what its place says.
        float size[3];
        const float origin[3] = {0, 0, 0};
        stretch(s, size);
        placed(row, origin, t, size);
        Colour c = colourOf(s.c);
        row[12] = c.r;
        row[13] = c.g;
        row[14] = c.b;
        row[15] = c.a;
        o->tint = s.c;
        places.setTransform(places.getInstance(o->entity), mat4f::translation(float3{s.p[0], s.p[1], s.p[2]}));
        auto& solids = engine.getRenderableManager();
        solids.setAxisAlignedBoundingBox(solids.getInstance(o->entity),
            filament::Box{float3(0.0f), float3(size[0] + size[1] + size[2])});
        show(o, o->visible);
    }

    void hide(Thing* o) {
        if (o->batch) {
            unseat(o);
            return;
        }
        if (o->crowd) {
            discharge(o);
            return;
        }
        o->visible = false;
        if (o->kind == LINE) { linesMoved = true; }
        show(o, false);
    }

    void shed(Thing* o) {
        if (o->batch) {
            unseat(o);
        } else if (o->crowd) {
            discharge(o);
        } else if (o->kind == LINE) {
            lines.erase(std::remove(lines.begin(), lines.end(), o), lines.end());
            linesMoved = true;
        }
        if (o->standing) {
            show(o, false);
            engine.destroy(o->entity);
            EntityManager::get().destroy(o->entity);
        }
        if (o->look) {
            unveiled(o->look);
            engine.destroy(o->look);
        }
        if (o->slot >= 0) { poolSpare.push_back(o->slot); }
        if (o->shared) {
            auto& users = o->shared->users;
            users.erase(std::remove(users.begin(), users.end(), o), users.end());
        }
        if (o->land) {
            if (o->land->form.points) { engine.destroy(o->land->form.points); }
            if (o->land->form.corners) { engine.destroy(o->land->form.corners); }
            delete o->land;
        }
        delete o;
    }

    void forget() {
        for (Thing* o : live) {
            if (o) { shed(o); }
        }
        live.clear();
        for (Heard* h : voiceOf) { delete h; }
        voiceOf.clear();
        soundsMoved = true;
    }

    void carried(Reader& r, uint32_t n) {
        std::vector<Thing*> was = live;
        std::vector<Heard*> heard = voiceOf;
        std::vector<uint32_t> runs(size_t(n) * 3);
        for (auto& v : runs) { v = r.u32(); }
        if (r.short_) { return; }
        carry++;
        auto solid = [&](uint32_t k) { return k < was.size() ? was[k] : nullptr; };
        auto voice = [&](uint32_t k) { return k < heard.size() ? heard[k] : nullptr; };
        for (size_t m = 0; m < runs.size(); m += 3) {
            for (uint32_t j = 0; j < runs[m + 2]; j++) {
                uint32_t k = runs[m + 1] + j;
                if (solid(k)) { solid(k)->carry = carry; }
                if (voice(k)) { voice(k)->carry = carry; }
            }
        }
        for (size_t m = 0; m < runs.size(); m += 3) {
            for (uint32_t j = 0; j < runs[m + 2]; j++) {
                uint32_t dst = runs[m] + j, src = runs[m + 1] + j;
                if (dst >= live.size()) { live.resize(size_t(dst) + 1, nullptr); }
                if (dst >= voiceOf.size()) { voiceOf.resize(size_t(dst) + 1, nullptr); }
                if (solid(dst) && solid(dst)->carry != carry) { shed(solid(dst)); }
                if (voice(dst) && voice(dst)->carry != carry) { delete voice(dst); }
                live[dst] = solid(src);
                voiceOf[dst] = voice(src);
            }
        }
        for (size_t m = 0; m < runs.size(); m += 3) {
            for (uint32_t j = 0; j < runs[m + 2]; j++) {
                uint32_t k = runs[m + 1] + j;
                if (solid(k) && k < live.size() && live[k] == solid(k)) { live[k] = nullptr; }
                if (voice(k) && k < voiceOf.size() && voiceOf[k] == voice(k)) { voiceOf[k] = nullptr; }
            }
        }
        soundsMoved = true;
    }

    void trim(uint32_t count) {
        for (size_t i = count; i < live.size(); i++) {
            if (live[i]) { hide(live[i]); }
        }
        for (size_t i = count; i < voiceOf.size(); i++) {
            if (voiceOf[i]) {
                delete voiceOf[i];
                voiceOf[i] = nullptr;
                soundsMoved = true;
            }
        }
    }

    void slotted(Reader& r, uint32_t at) {
        int kind = r.u8(), mask = r.u8();
        if (at >= live.size()) { live.resize(size_t(at) + 1, nullptr); }
        if (at >= voiceOf.size()) { voiceOf.resize(size_t(at) + 1, nullptr); }
        if (kind == SOUND) {
            Heard* heard = voiceOf[at];
            if (!heard) {
                heard = new Heard();
                voiceOf[at] = heard;
            }
            heard->p[0] = r.f32();
            heard->p[1] = r.f32();
            heard->p[2] = r.f32();
            heard->name = r.longText();
            heard->voice = (mask & HAS_VOICE) ? r.word() : "";
            heard->track = (mask & HAS_TRACK) ? r.word() : "";
            heard->pitch = r.f32();
            heard->volume = r.f32();
            soundsMoved = true;
            if (live[at]) {
                shed(live[at]);
                live[at] = nullptr;
            }
            return;
        }
        if (voiceOf[at]) {
            delete voiceOf[at];
            voiceOf[at] = nullptr;
            soundsMoved = true;
        }
        Record s;
        s.kind = kind < KINDS ? kind : BOX;
        s.c = r.word();
        if (mask & HAS_AT) {
            for (float& v : s.p) { v = r.f32(); }
        }
        s.turned = (mask & HAS_TURN) != 0;
        if (s.turned) {
            for (float& v : s.r) { v = r.f32(); }
        }
        if (mask & HAS_SCALE) {
            for (float& v : s.z) { v = r.f32(); }
        }
        if (mask & HAS_SIZE) {
            s.d.resize(r.u8());
            for (float& v : s.d) { v = r.f32(); }
        } else if (s.kind != FIGURE) {
            s.d = {1, 1, 1};
        }
        if (mask & HAS_SURFACE) { s.s = r.word(); }
        if (mask & HAS_WORDS) { s.x = r.longText(); }
        if (mask & HAS_PAINTS) {
            s.t.resize(r.u8());
            for (auto& tone : s.t) { tone = r.word(); }
        }
        if (r.short_) { return; }
        Thing* o = live[at];
        if (!fits(o, s)) {
            if (o) { shed(o); }
            o = build(s);
            live[at] = o;
        }
        if (!o->visible && o->kind == LINE) { linesMoved = true; }
        o->visible = true;
        put(o, s);
    }

    static void readEye(Reader& r, Eye& into) {
        for (float& v : into.eye) { v = r.f32(); }
        for (float& v : into.aim) { v = r.f32(); }
        int bits = r.u8();
        into.lens = (bits & EYE_LENS) ? r.u16() : 0;
        into.fog = (bits & EYE_FOG) ? r.u16() : 0;
        into.grain = (bits & EYE_GRAIN) ? r.u16() : 0;
        into.bits = (bits & EYE_BITS) ? r.u16() : 0;
        into.sky = (bits & EYE_SKY) ? r.word() : "";
        into.grab = (bits & EYE_GRAB) != 0;
        into.flat = (bits & EYE_FLAT) != 0;
        if (bits & EYE_SUN) {
            into.sun[0] = r.f32();
            into.sun[1] = r.f32();
            into.shade = r.u16();
        } else {
            into.sun[0] = 0;
            into.sun[1] = -100;
            into.shade = 0;
        }
        into.on = r.word();
    }

    bool paint(const uint8_t* data, size_t size) {
        Reader r(data, size);
        uint32_t stamp = r.u32(), after = r.u32();
        if (after != 0 && after != seq) { return false; }
        Eye eye;
        readEye(r, eye);
        uint32_t count = r.u32();
        int many = r.u8();
        std::vector<Eye> others;
        others.resize(size_t(many));
        for (auto& other : others) { readEye(r, other); }
        if (r.short_) { return true; }
        world = eye;
        looks = others;
        if (after == 0) { forget(); }
        uint32_t moves = r.u32();
        if (moves) { carried(r, moves); }
        uint32_t edits = r.u32();
        for (uint32_t e = 0; e < edits && !r.short_; e++) { slotted(r, r.u32()); }
        trim(count);
        seq = stamp;
        apply();
        dirty = true;
        return true;
    }

    void apply() {
        const Eye& w = world;
        if (w.grain != coarse || w.bits != deep) {
            coarse = w.grain;
            deep = w.bits;
            shaped = true;
        }
        bool skied = !w.sky.empty();
        if (skied) { heavens(w.sky); }
        if (skied != skyStaged) {
            stage->setSkybox(skied ? sky : nullptr);
            skyStaged = skied;
        }
        lit(skied ? w.sky : "#8ecbff");
        float near = w.fog ? float(w.fog) * 0.5f : 0, far = float(w.fog), on = w.fog ? 1.0f : 0.0f;
        if (near != fogNear || far != fogFar || on != fogOn) {
            fogNear = near;
            fogFar = far;
            fogOn = on;
            fogged();
        }
        float far2 = w.shade ? float(w.shade) : 55.0f;
        if (!sunSet || far2 != shadeFar || w.sun[0] != sunAt[0] || w.sun[1] != sunAt[1]) { sunned(w.sun, far2); }
        if (soundsMoved) {
            soundsMoved = false;
            sounded.clear();
            for (Heard* h : voiceOf) {
                if (h) { sounded.push_back(h); }
            }
        }
    }

    void aimed(Sight& l, const Eye& e, int wide, int tall) {
        float lens = e.lens ? float(e.lens) : 75.0f;
        l.camera->setProjection(double(lens), double(wide) / double(std::max(1, tall)), 0.08, 800.0,
            Camera::Fov::VERTICAL);
        Turn t = turned(e.aim[1], e.aim[0], 0);
        mat4f m;
        m[0] = float4{t.m[0], t.m[1], t.m[2], 0};
        m[1] = float4{t.m[3], t.m[4], t.m[5], 0};
        m[2] = float4{t.m[6], t.m[7], t.m[8], 0};
        m[3] = float4{e.eye[0], e.eye[1], e.eye[2], 1};
        l.camera->setModelMatrix(m);
    }

    void backed(Sight& l, int wide, int tall) {
        wide = std::max(1, wide);
        tall = std::max(1, tall);
        if (l.target && l.wide == wide && l.tall == tall) { return; }
        // The old one is let go a few frames on: the frame after a change still reads it.
        Texture* colour = Texture::Builder().width(uint32_t(wide)).height(uint32_t(tall)).levels(1)
            .sampler(Texture::Sampler::SAMPLER_2D).format(Texture::InternalFormat::RGBA8)
            .usage(Texture::Usage::COLOR_ATTACHMENT | Texture::Usage::SAMPLEABLE).name("sight", 5).build(engine);
        RenderTarget* target = RenderTarget::Builder().texture(RenderTarget::AttachmentPoint::COLOR, colour)
            .build(engine);
        l.view->setRenderTarget(target);
        l.sheet->setParameter("picture", colour, exact());
        if (l.target) { spent.push_back(Spent{l.target, l.colour, 3}); }
        l.colour = colour;
        l.target = target;
        l.view->setViewport(Viewport{0, 0, uint32_t(wide), uint32_t(tall)});
        l.wide = wide;
        l.tall = tall;
    }

    void laidOut(Sight& l, float left, float top, float wide, float tall) {
        float x0 = left / float(sheetWide) * 2 - 1, x1 = (left + wide) / float(sheetWide) * 2 - 1;
        float y1 = 1 - top / float(sheetTall) * 2, y0 = 1 - (top + tall) / float(sheetTall) * 2;
        float v0 = upside ? 1.0f : 0.0f, v1 = 1 - v0;
        const float corners[] = {x0, y0, 0, 0, v0, x1, y0, 0, 1, v0, x1, y1, 0, 1, v1, x0, y1, 0, 0, v1};
        l.corners->setBufferAt(engine, 0, kept(corners, sizeof(corners)));
        bool rough = coarse > 0;
        l.sheet->setParameter("picture", l.colour, TextureSampler(
            rough ? TextureSampler::MinFilter::NEAREST : TextureSampler::MinFilter::LINEAR,
            rough ? TextureSampler::MagFilter::NEAREST : TextureSampler::MagFilter::LINEAR));
        float steps = deep > 0 ? std::pow(2.0f, float(deep)) - 1 : 0;
        l.sheet->setParameter("shape", float4{steps, traded ? 1.0f : 0.0f, upside ? 1.0f : 0.0f, 0});
        l.sheet->setParameter("frame", float4{float(main.wide), float(main.tall), float(sheetWide), float(sheetTall)});
    }

    void staged(Sight& l, bool on) {
        if (l.staged == on) { return; }
        if (on) { page->addEntity(l.quad); }
        else { page->remove(l.quad); }
        l.staged = on;
    }

    void render(Renderer& renderer, bool upsideDown, bool swapped) {
        upside = upsideDown;
        traded = swapped;
        float shrink = 1;
        if (coarse > 0) { shrink = std::min(1.0f, float(coarse) / float(std::max(1, std::min(drawnWide, drawnTall)))); }
        backed(main, int(std::lround(float(drawnWide) * shrink)), int(std::lround(float(drawnTall) * shrink)));
        aimed(main, world, drawnWide, drawnTall);
        main.view->setShadowingEnabled(!world.flat);
        laidOut(main, 0, 0, float(sheetWide), float(sheetTall));
        staged(main, true);
        sheetView->setViewport(Viewport{0, 0, uint32_t(sheetWide), uint32_t(sheetTall)});

        while (insets.size() < looks.size()) {
            insets.push_back(looking());
            auto& solids = engine.getRenderableManager();
            solids.setPriority(solids.getInstance(insets.back().quad), 5);
        }
        while (insets.size() > looks.size()) {
            unlooked(insets.back());
            insets.pop_back();
        }
        float density = float(sheetWide) / float(std::max(1, drawnWide));
        std::vector<Sight*> drawn;
        for (size_t i = 0; i < insets.size(); i++) {
            Sight& l = insets[i];
            Box box = i < boxes.size() ? boxes[i] : Box();
            int left = std::max(0, box.left), top = std::max(0, box.top);
            int right = std::min(sheetWide, box.left + box.wide), low = std::min(sheetTall, box.top + box.tall);
            float wide = float(right - left) / density, tall = float(low - top) / density;
            if (wide < 8 || tall < 8) {
                staged(l, false);
                continue;
            }
            backed(l, int(std::lround(wide * shrink)), int(std::lround(tall * shrink)));
            aimed(l, looks[i], right - left, low - top);
            l.view->setShadowingEnabled(!world.flat);
            laidOut(l, float(left), float(top), float(right - left), float(low - top));
            staged(l, true);
            drawn.push_back(&l);
        }

        for (auto& all : batches) {
            for (Batch* b : all.second) {
                if (b->high >= b->low) { bounded(b->entity, b->rows, b->seats.size()); }
                upload(b->things, b->rows, b->low, b->high);
            }
        }
        upload(pool, poolRows, poolLow, poolHigh);
        for (auto& each : crowds) {
            Crowd& c = *each.second;
            if (c.high < c.low || !c.bones) { continue; }
            float3 least(1e30f), most(-1e30f);
            for (size_t i = 0; i < c.seats.size(); i++) {
                const float* r = &c.boneRows[i * size_t(c.wide) * 4];
                float reach = c.reach * std::max(std::sqrt(r[0] * r[0] + r[4] * r[4] + r[8] * r[8]),
                    std::max(std::sqrt(r[1] * r[1] + r[5] * r[5] + r[9] * r[9]),
                        std::sqrt(r[2] * r[2] + r[6] * r[6] + r[10] * r[10])));
                float3 at{r[3], r[7], r[11]};
                least = min(least, at - float3(reach));
                most = max(most, at + float3(reach));
            }
            if (!c.seats.empty()) {
                auto& solids = engine.getRenderableManager();
                solids.setAxisAlignedBoundingBox(solids.getInstance(c.entity),
                    filament::Box{(least + most) * 0.5f, (most - least) * 0.5f});
            }
            int rows = c.high - c.low + 1;
            size_t wide = size_t(c.wide) * 4;
            c.bones->setImage(engine, 0, 0, uint32_t(c.low), uint32_t(c.wide), uint32_t(rows),
                pixels(&c.boneRows[size_t(c.low) * wide], size_t(rows) * wide * 4, Texture::Format::RGBA,
                    Texture::Type::FLOAT));
            c.paints->setImage(engine, 0, 0, uint32_t(c.low), PARTS, uint32_t(rows),
                pixels(&c.paintRows[size_t(c.low) * PARTS * 4], size_t(rows) * PARTS * 16, Texture::Format::RGBA,
                    Texture::Type::FLOAT));
            c.low = 1 << 30;
            c.high = -1;
        }
        ruled();

        renderer.render(main.view);
        for (Sight* l : drawn) { renderer.render(l->view); }
        renderer.render(sheetView);
        for (size_t i = 0; i < spent.size();) {
            if (--spent[i].frames > 0) {
                i++;
                continue;
            }
            engine.destroy(spent[i].target);
            engine.destroy(spent[i].colour);
            spent.erase(spent.begin() + long(i));
        }
        dirty = false;
        shaped = false;
    }
};

World::World(Engine& engine, Host& host) : in(new Inner(engine, host)) { in->setup(); }

World::~World() {
    // The engine is destroyed after this, and takes what is left with it.
    in->forget();
}

bool World::frame(const uint8_t* data, size_t size) { return in->paint(data, size); }

void World::sized(int sheetWide, int sheetTall, int drawnWide, int drawnTall) {
    sheetWide = std::max(1, sheetWide);
    sheetTall = std::max(1, sheetTall);
    drawnWide = std::max(1, drawnWide);
    drawnTall = std::max(1, drawnTall);
    if (sheetWide == in->sheetWide && sheetTall == in->sheetTall && drawnWide == in->drawnWide &&
            drawnTall == in->drawnTall) {
        return;
    }
    in->sheetWide = sheetWide;
    in->sheetTall = sheetTall;
    in->drawnWide = drawnWide;
    in->drawnTall = drawnTall;
    in->dirty = true;
}

void World::insetsAt(const std::vector<Box>& boxes) {
    in->boxes = boxes;
    in->dirty = true;
}

void World::draw(Renderer& renderer, bool upsideDown, bool traded) { in->render(renderer, upsideDown, traded); }

void World::picture(const std::string& path, int wide, int tall, const uint8_t* rgba) {
    Inner& w = *in;
    const std::string folder = "textures/";
    if (path.compare(0, folder.size(), folder) == 0 && path.size() > folder.size() + 4) {
        std::string name = path.substr(folder.size(), path.size() - folder.size() - 4);
        Picture& p = w.photos[name];
        if (rgba && wide > 0 && tall > 0) {
            p.wide = wide;
            p.tall = tall;
            p.rgba.assign(rgba, rgba + size_t(wide) * tall * 4);
            std::string finish = name;
            size_t dash = finish.find("-normal");
            if (dash != std::string::npos) { finish = finish.substr(0, dash); }
            for (auto& each : w.skins) {
                if (Inner::lower(each.first) == finish) {
                    w.woven(each.second);
                    w.dirty = true;
                }
            }
        }
    }
    auto found = w.pics.find(path);
    if (found == w.pics.end() || !rgba || wide <= 0 || tall <= 0) { return; }
    Shared& s = *found->second;
    if (s.texture) { return; }
    s.texture = w.shown(wide, tall, rgba);
    for (Thing* o : s.users) { w.worn(o); }
    w.dirty = true;
}

void World::file(const std::string& path, const uint8_t* data, size_t size, bool found) {
    Inner& w = *in;
    auto held = w.crowds.find(path);
    if (held == w.crowds.end()) { return; }
    Crowd& c = *held->second;
    if (c.model.ready || c.failed) { return; }
    if (!found || !readModel(c.model, data, size)) {
        c.failed = true;
        c.model = Model();
        return;
    }
    w.muster(c);
    w.dirty = true;
}

void World::terrain(const std::string& id, const uint8_t* data, size_t size) {
    Inner& w = *in;
    if (!data || size < 12) { return; }
    if (w.grounds.size() > 8) { w.grounds.clear(); }
    w.grounds[id].assign(data, data + size);
    for (Thing* o : w.live) {
        if (o && o->land && o->land->asked == id && o->land->laid != id) {
            w.laid(o, data, size);
            w.dirty = true;
        }
    }
}

void World::label(const std::string& words, const std::string& colour, int wide, int tall, const uint8_t* rgba) {
    Inner& w = *in;
    auto found = w.signs.find(words + "|" + colour);
    if (found == w.signs.end() || !rgba || wide <= 0 || tall <= 0) { return; }
    Shared& s = *found->second;
    if (s.texture) { return; }
    s.texture = w.shown(wide, tall, rgba);
    s.aspect = float(wide) / float(tall);
    for (Thing* o : s.users) { w.worn(o); }
    w.dirty = true;
}

bool World::stale() const { return in->dirty; }

const Eye& World::eye() const { return in->world; }

const std::vector<const Heard*>& World::sounds() { return in->sounded; }

} // namespace hive
