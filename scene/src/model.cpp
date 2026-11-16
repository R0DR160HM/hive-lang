#include "model.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <utility>

namespace hive {

namespace {

struct Json {
    enum Kind { Null, Bool, Number, Text, List, Dict } kind = Null;
    double number = 0;
    std::string text;
    std::vector<Json> list;
    std::vector<std::pair<std::string, Json>> dict;

    const Json* get(const char* key) const {
        for (const auto& kv : dict) {
            if (kv.first == key) { return &kv.second; }
        }
        return nullptr;
    }
    bool has(const char* key) const { return get(key) != nullptr; }
    double num(const char* key, double fallback) const {
        const Json* v = get(key);
        return v && v->kind == Number ? v->number : fallback;
    }
    int whole(const char* key, int fallback) const { return int(num(key, fallback)); }
    size_t size() const { return list.size(); }
    const Json& at(size_t i) const { return list[i]; }
};

struct Parser {
    const char* p;
    const char* end;
    bool bad = false;

    void space() {
        while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) { p++; }
    }

    std::string str() {
        std::string out;
        p++;
        while (p < end && *p != '"') {
            if (*p == '\\' && p + 1 < end) {
                p++;
                switch (*p) {
                case 'n': out += '\n'; break;
                case 't': out += '\t'; break;
                case 'r': out += '\r'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'u': {
                    unsigned code = 0;
                    for (int i = 0; i < 4 && p + 1 < end; i++) {
                        p++;
                        code = code * 16 + unsigned(std::strtol(std::string(1, *p).c_str(), nullptr, 16));
                    }
                    if (code < 0x80) { out += char(code); }
                    else if (code < 0x800) {
                        out += char(0xC0 | (code >> 6));
                        out += char(0x80 | (code & 0x3F));
                    } else {
                        out += char(0xE0 | (code >> 12));
                        out += char(0x80 | ((code >> 6) & 0x3F));
                        out += char(0x80 | (code & 0x3F));
                    }
                    break;
                }
                default: out += *p;
                }
            } else {
                out += *p;
            }
            p++;
        }
        if (p < end) { p++; }
        else { bad = true; }
        return out;
    }

    Json value(int depth = 0) {
        Json v;
        space();
        if (p >= end || depth > 64) {
            bad = true;
            return v;
        }
        if (*p == '{') {
            v.kind = Json::Dict;
            p++;
            space();
            if (p < end && *p == '}') {
                p++;
                return v;
            }
            while (p < end && !bad) {
                space();
                if (p >= end || *p != '"') {
                    bad = true;
                    break;
                }
                std::string key = str();
                space();
                if (p >= end || *p != ':') {
                    bad = true;
                    break;
                }
                p++;
                v.dict.emplace_back(std::move(key), value(depth + 1));
                space();
                if (p < end && *p == ',') {
                    p++;
                    continue;
                }
                if (p < end && *p == '}') {
                    p++;
                    break;
                }
                bad = true;
            }
            return v;
        }
        if (*p == '[') {
            v.kind = Json::List;
            p++;
            space();
            if (p < end && *p == ']') {
                p++;
                return v;
            }
            while (p < end && !bad) {
                v.list.push_back(value(depth + 1));
                space();
                if (p < end && *p == ',') {
                    p++;
                    continue;
                }
                if (p < end && *p == ']') {
                    p++;
                    break;
                }
                bad = true;
            }
            return v;
        }
        if (*p == '"') {
            v.kind = Json::Text;
            v.text = str();
            return v;
        }
        if (end - p >= 4 && !strncmp(p, "true", 4)) {
            v.kind = Json::Bool;
            v.number = 1;
            p += 4;
            return v;
        }
        if (end - p >= 5 && !strncmp(p, "false", 5)) {
            v.kind = Json::Bool;
            p += 5;
            return v;
        }
        if (end - p >= 4 && !strncmp(p, "null", 4)) {
            p += 4;
            return v;
        }
        const char* from = p;
        while (p < end && (*p == '-' || *p == '+' || *p == '.' || *p == 'e' || *p == 'E' || (*p >= '0' && *p <= '9'))) {
            p++;
        }
        if (p == from) {
            bad = true;
            return v;
        }
        v.kind = Json::Number;
        v.number = std::strtod(std::string(from, p).c_str(), nullptr);
        return v;
    }
};

struct Column {
    std::vector<double> values;
    int wide = 1;
    double top = 1;
    bool ok = false;
};

uint32_t word(const uint8_t* p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}

struct File {
    Json doc;
    const uint8_t* bin = nullptr;
    size_t binSize = 0;

    Column read(int i) const {
        Column out;
        const Json* accessors = doc.get("accessors");
        const Json* views = doc.get("bufferViews");
        if (!accessors || !views || i < 0 || size_t(i) >= accessors->size()) { return out; }
        const Json& a = accessors->at(size_t(i));
        int view = a.whole("bufferView", -1);
        if (view < 0 || size_t(view) >= views->size()) { return out; }
        const Json& v = views->at(size_t(view));
        const Json* type = a.get("type");
        std::string kind = type ? type->text : "";
        out.wide = kind == "SCALAR" ? 1 : kind == "VEC2" ? 2 : kind == "VEC3" ? 3 : kind == "VEC4" ? 4
            : kind == "MAT4" ? 16 : 0;
        int component = a.whole("componentType", 0);
        int bytes = component == 5120 || component == 5121 ? 1 : component == 5122 || component == 5123 ? 2
            : component == 5125 || component == 5126 ? 4 : 0;
        if (out.wide == 0 || bytes == 0) { return out; }
        size_t count = size_t(a.num("count", 0));
        size_t each = size_t(out.wide) * size_t(bytes);
        size_t step = size_t(v.num("byteStride", 0));
        if (step == 0) { step = each; }
        size_t from = size_t(v.num("byteOffset", 0)) + size_t(a.num("byteOffset", 0));
        if (count == 0 || from + (count - 1) * step + each > binSize) { return out; }
        out.values.resize(count * size_t(out.wide));
        for (size_t k = 0; k < count; k++) {
            const uint8_t* p = bin + from + k * step;
            for (int c = 0; c < out.wide; c++) {
                const uint8_t* q = p + size_t(c) * size_t(bytes);
                double value = 0;
                if (component == 5121) { value = q[0]; }
                else if (component == 5120) { value = int8_t(q[0]); }
                else if (component == 5123) { value = uint16_t(q[0] | q[1] << 8); }
                else if (component == 5122) { value = int16_t(uint16_t(q[0] | q[1] << 8)); }
                else if (component == 5125) { value = word(q); }
                else {
                    float f;
                    memcpy(&f, q, 4);
                    value = f;
                }
                out.values[k * size_t(out.wide) + size_t(c)] = value;
            }
        }
        const Json* normalised = a.get("normalized");
        if (normalised && normalised->number != 0) {
            out.top = component == 5121 ? 255 : component == 5123 ? 65535 : component == 5120 ? 127
                : component == 5122 ? 32767 : 1;
        }
        out.ok = true;
        return out;
    }
};

// Column by column, as a glTF writes a matrix.
struct Mat {
    double m[16];
};

Mat identity() {
    Mat r;
    for (int i = 0; i < 16; i++) { r.m[i] = (i % 5 == 0) ? 1 : 0; }
    return r;
}

Mat times(const Mat& a, const Mat& b) {
    Mat r;
    for (int c = 0; c < 4; c++) {
        for (int row = 0; row < 4; row++) {
            double s = 0;
            for (int k = 0; k < 4; k++) { s += a.m[k * 4 + row] * b.m[c * 4 + k]; }
            r.m[c * 4 + row] = s;
        }
    }
    return r;
}

Mat composed(const double t[3], const double q[4], const double s[3]) {
    double x = q[0], y = q[1], z = q[2], w = q[3];
    double x2 = x + x, y2 = y + y, z2 = z + z;
    double xx = x * x2, xy = x * y2, xz = x * z2, yy = y * y2, yz = y * z2, zz = z * z2;
    double wx = w * x2, wy = w * y2, wz = w * z2;
    Mat r;
    r.m[0] = (1 - (yy + zz)) * s[0];
    r.m[1] = (xy + wz) * s[0];
    r.m[2] = (xz - wy) * s[0];
    r.m[3] = 0;
    r.m[4] = (xy - wz) * s[1];
    r.m[5] = (1 - (xx + zz)) * s[1];
    r.m[6] = (yz + wx) * s[1];
    r.m[7] = 0;
    r.m[8] = (xz + wy) * s[2];
    r.m[9] = (yz - wx) * s[2];
    r.m[10] = (1 - (xx + yy)) * s[2];
    r.m[11] = 0;
    r.m[12] = t[0];
    r.m[13] = t[1];
    r.m[14] = t[2];
    r.m[15] = 1;
    return r;
}

void taken(const Mat& mx, Joint& j) {
    const double* m = mx.m;
    double sx = std::sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
    double sy = std::sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
    double sz = std::sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]);
    double det = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[4] * (m[1] * m[10] - m[2] * m[9]) +
        m[8] * (m[1] * m[6] - m[2] * m[5]);
    if (det < 0) { sx = -sx; }
    j.t[0] = float(m[12]);
    j.t[1] = float(m[13]);
    j.t[2] = float(m[14]);
    j.s[0] = float(sx);
    j.s[1] = float(sy);
    j.s[2] = float(sz);
    double ix = sx != 0 ? 1 / sx : 0, iy = sy != 0 ? 1 / sy : 0, iz = sz != 0 ? 1 / sz : 0;
    double m11 = m[0] * ix, m21 = m[1] * ix, m31 = m[2] * ix;
    double m12 = m[4] * iy, m22 = m[5] * iy, m32 = m[6] * iy;
    double m13 = m[8] * iz, m23 = m[9] * iz, m33 = m[10] * iz;
    double trace = m11 + m22 + m33, x, y, z, w;
    if (trace > 0) {
        double s = 0.5 / std::sqrt(trace + 1.0);
        w = 0.25 / s;
        x = (m32 - m23) * s;
        y = (m13 - m31) * s;
        z = (m21 - m12) * s;
    } else if (m11 > m22 && m11 > m33) {
        double s = 2.0 * std::sqrt(1.0 + m11 - m22 - m33);
        w = (m32 - m23) / s;
        x = 0.25 * s;
        y = (m12 + m21) / s;
        z = (m13 + m31) / s;
    } else if (m22 > m33) {
        double s = 2.0 * std::sqrt(1.0 + m22 - m11 - m33);
        w = (m13 - m31) / s;
        x = (m12 + m21) / s;
        y = 0.25 * s;
        z = (m23 + m32) / s;
    } else {
        double s = 2.0 * std::sqrt(1.0 + m33 - m11 - m22);
        w = (m21 - m12) / s;
        x = (m13 + m31) / s;
        y = (m23 + m32) / s;
        z = 0.25 * s;
    }
    j.r[0] = float(x);
    j.r[1] = float(y);
    j.r[2] = float(z);
    j.r[3] = float(w);
}

} // namespace

bool readModel(Model& m, const uint8_t* data, size_t size) {
    if (size < 20 || word(data) != 0x46546C67) { return false; }
    File file;
    bool described = false;
    size_t at = 12;
    while (at + 8 <= size) {
        size_t length = word(data + at);
        uint32_t kind = word(data + at + 4);
        if (at + 8 + length > size) { break; }
        if (kind == 0x4E4F534A) {
            Parser parser{reinterpret_cast<const char*>(data + at + 8),
                reinterpret_cast<const char*>(data + at + 8 + length)};
            file.doc = parser.value();
            described = !parser.bad;
        }
        if (kind == 0x004E4942) {
            file.bin = data + at + 8;
            file.binSize = length;
        }
        at += 8 + length;
    }
    if (!described || !file.bin) { return false; }
    const Json& doc = file.doc;
    const Json* nodes = doc.get("nodes");
    const Json* skins = doc.get("skins");
    const Json* meshes = doc.get("meshes");
    const Json* accessors = doc.get("accessors");
    if (!nodes || !meshes || !accessors) { return false; }

    std::vector<int> upOf(nodes->size(), -1);
    for (size_t i = 0; i < nodes->size(); i++) {
        const Json* kids = nodes->at(i).get("children");
        if (!kids) { continue; }
        for (size_t c = 0; c < kids->size(); c++) {
            int kid = int(kids->at(c).number);
            if (kid >= 0 && kid < int(upOf.size())) { upOf[size_t(kid)] = int(i); }
        }
    }
    auto local = [&](int i) {
        const Json& nd = nodes->at(size_t(i));
        const Json* mx = nd.get("matrix");
        if (mx && mx->size() == 16) {
            Mat r;
            for (int k = 0; k < 16; k++) { r.m[k] = mx->at(size_t(k)).number; }
            return r;
        }
        double t[3] = {0, 0, 0}, q[4] = {0, 0, 0, 1}, s[3] = {1, 1, 1};
        const Json* jt = nd.get("translation");
        const Json* jr = nd.get("rotation");
        const Json* js = nd.get("scale");
        for (int k = 0; k < 3; k++) {
            if (jt && jt->size() == 3) { t[k] = jt->at(size_t(k)).number; }
            if (js && js->size() == 3) { s[k] = js->at(size_t(k)).number; }
        }
        for (int k = 0; k < 4; k++) {
            if (jr && jr->size() == 4) { q[k] = jr->at(size_t(k)).number; }
        }
        return composed(t, q, s);
    };

    // Every node that holds a mesh is drawn; the first one with a skin says what the joints are.
    std::vector<int> drawn;
    int skinAt = -1;
    for (size_t n = 0; n < nodes->size(); n++) {
        const Json& nd = nodes->at(n);
        int mesh = nd.whole("mesh", -1);
        if (mesh < 0 || size_t(mesh) >= meshes->size()) { continue; }
        drawn.push_back(int(n));
        int skin = nd.whole("skin", -1);
        if (skinAt < 0 && skins && skin >= 0 && size_t(skin) < skins->size()) { skinAt = skin; }
    }
    if (drawn.empty()) { return false; }
    std::vector<int> jointNodes;
    if (skinAt >= 0) {
        const Json* skinJoints = skins->at(size_t(skinAt)).get("joints");
        if (!skinJoints) { return false; }
        for (size_t k = 0; k < skinJoints->size(); k++) {
            int node = int(skinJoints->at(k).number);
            if (node < 0 || size_t(node) >= nodes->size()) { return false; }
            jointNodes.push_back(node);
        }
    }
    const size_t skinned = jointNodes.size();
    auto jointOf = [&](int node) {
        auto found = std::find(jointNodes.begin(), jointNodes.end(), node);
        return found == jointNodes.end() ? -1 : int(found - jointNodes.begin());
    };
    // A mesh with no skin rides a joint of its own, after the skin's, with every node above it a joint too.
    auto enlist = [&](int node) {
        std::vector<int> chain;
        for (int k = node, guard = 0; k >= 0 && jointOf(k) < 0 && guard < 1024; k = upOf[size_t(k)], guard++) {
            chain.push_back(k);
        }
        for (size_t i = chain.size(); i > 0; i--) { jointNodes.push_back(chain[i - 1]); }
        return jointOf(node);
    };

    for (int k = 0; k < PARTS * 4; k++) { m.tints[k] = 1; }
    bool normals = true;
    const Json* materials = doc.get("materials");
    size_t part = 0;
    for (int node : drawn) {
        const Json& nd = nodes->at(size_t(node));
        bool rides = nd.whole("skin", -1) != skinAt || skinAt < 0;
        int own = rides ? enlist(node) : -1;
        const Json* prims = meshes->at(size_t(nd.whole("mesh", -1))).get("primitives");
        if (!prims) { continue; }
        for (size_t k = 0; k < prims->size(); k++, part++) {
            const Json& p = prims->at(k);
            int mode = p.whole("mode", 4);
            if (mode != 4) { continue; }
            const Json* q = p.get("attributes");
            if (!q) { return false; }
            Column place = file.read(q->whole("POSITION", -1));
            if (!place.ok || place.wide != 3) { return false; }
            size_t many = place.values.size() / 3, base = m.place.size() / 3;
            for (double v : place.values) { m.place.push_back(float(v)); }
            m.facing.resize((base + many) * 3, 0);
            if (q->has("NORMAL")) {
                Column facing = file.read(q->whole("NORMAL", -1));
                if (facing.ok && facing.values.size() == many * 3) {
                    for (size_t i = 0; i < many * 3; i++) { m.facing[base * 3 + i] = float(facing.values[i] / facing.top); }
                } else {
                    normals = false;
                }
            } else {
                normals = false;
            }
            m.tint.resize((base + many) * 3, 255);
            if (q->has("COLOR_0")) {
                Column c = file.read(q->whole("COLOR_0", -1));
                if (c.ok && c.wide >= 3 && c.values.size() == many * size_t(c.wide)) {
                    double scale = c.top == 1 ? 255 : 255 / c.top;
                    for (size_t i = 0; i < many; i++) {
                        for (int ch = 0; ch < 3; ch++) {
                            double v = std::nearbyint(c.values[i * size_t(c.wide) + size_t(ch)] * scale);
                            m.tint[(base + i) * 3 + size_t(ch)] = uint8_t(std::min(255.0, std::max(0.0, v)));
                        }
                    }
                }
            }
            if (rides) {
                for (size_t i = 0; i < many; i++) {
                    m.bones.insert(m.bones.end(), {float(own), 0, 0, 0});
                    m.weights.insert(m.weights.end(), {1, 0, 0, 0});
                }
            } else {
                Column bones = file.read(q->whole("JOINTS_0", -1));
                Column weights = file.read(q->whole("WEIGHTS_0", -1));
                if (!bones.ok || !weights.ok || bones.values.size() != many * 4 || weights.values.size() != many * 4) {
                    return false;
                }
                for (double v : bones.values) { m.bones.push_back(float(v)); }
                for (double v : weights.values) { m.weights.push_back(float(v / weights.top)); }
            }
            m.part.resize(base + many, uint8_t(std::min<size_t>(part, PARTS - 1)));
            if (p.has("indices")) {
                Column index = file.read(p.whole("indices", -1));
                if (!index.ok) { return false; }
                for (double v : index.values) { m.index.push_back(uint32_t(v) + uint32_t(base)); }
            } else {
                for (size_t i = 0; i < many; i++) { m.index.push_back(uint32_t(base + i)); }
            }
            int material = p.whole("material", -1);
            if (materials && material >= 0 && size_t(material) < materials->size() && part < size_t(PARTS)) {
                const Json* pbr = materials->at(size_t(material)).get("pbrMetallicRoughness");
                const Json* colour = pbr ? pbr->get("baseColorFactor") : nullptr;
                if (colour && colour->size() >= 3) {
                    m.tints[part * 4] = float(colour->at(0).number);
                    m.tints[part * 4 + 1] = float(colour->at(1).number);
                    m.tints[part * 4 + 2] = float(colour->at(2).number);
                    m.tints[part * 4 + 3] = 1;
                }
            }
        }
    }
    size_t count = m.place.size() / 3;
    if (count == 0 || jointNodes.size() > 500) { return false; }
    for (uint32_t i : m.index) {
        if (i >= count) { return false; }
    }
    if (!normals) {
        std::fill(m.facing.begin(), m.facing.end(), 0.0f);
        for (size_t t = 0; t + 2 < m.index.size(); t += 3) {
            const float* a = &m.place[m.index[t] * 3];
            const float* b = &m.place[m.index[t + 1] * 3];
            const float* c = &m.place[m.index[t + 2] * 3];
            float cb[3] = {c[0] - b[0], c[1] - b[1], c[2] - b[2]}, ab[3] = {a[0] - b[0], a[1] - b[1], a[2] - b[2]};
            float n[3] = {cb[1] * ab[2] - cb[2] * ab[1], cb[2] * ab[0] - cb[0] * ab[2], cb[0] * ab[1] - cb[1] * ab[0]};
            for (int v = 0; v < 3; v++) {
                for (int k = 0; k < 3; k++) { m.facing[m.index[t + size_t(v)] * 3 + size_t(k)] += n[k]; }
            }
        }
        for (size_t i = 0; i < count; i++) {
            float* n = &m.facing[i * 3];
            float len = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
            if (len > 0) {
                n[0] /= len;
                n[1] /= len;
                n[2] /= len;
            }
        }
    }

    // A joint whose parent is no joint keeps the file's world transform.
    for (size_t k = 0; k < jointNodes.size(); k++) {
        int node = jointNodes[k];
        Mat mx = local(node);
        int up = upOf[size_t(node)];
        int parent = up >= 0 ? jointOf(up) : -1;
        if (parent < 0) {
            int guard = 0;
            for (; up >= 0 && guard < 1024; up = upOf[size_t(up)], guard++) { mx = times(local(up), mx); }
        }
        Joint j;
        j.parent = parent;
        taken(mx, j);
        m.joints.push_back(j);
    }
    m.inverses.assign(m.joints.size() * 16, 0);
    for (size_t k = 0; k < m.joints.size(); k++) {
        for (int d = 0; d < 4; d++) { m.inverses[k * 16 + size_t(d) * 5] = 1; }
    }
    if (skinAt >= 0 && skins->at(size_t(skinAt)).has("inverseBindMatrices")) {
        Column inv = file.read(skins->at(size_t(skinAt)).whole("inverseBindMatrices", -1));
        if (inv.ok && inv.values.size() >= skinned * 16) {
            for (size_t i = 0; i < skinned * 16; i++) { m.inverses[i] = float(inv.values[i]); }
        }
    }
    for (float b : m.bones) {
        if (b < 0 || size_t(b) >= m.joints.size()) { return false; }
    }
    // Parents before their children, whatever order the file lists them in.
    std::vector<char> stood(m.joints.size(), 0);
    for (size_t each = 0; each < m.joints.size(); each++) {
        std::vector<int> chain;
        int k = int(each), guard = 0;
        while (k >= 0 && !stood[size_t(k)] && guard < 4096) {
            chain.push_back(k);
            stood[size_t(k)] = 1;
            k = m.joints[size_t(k)].parent;
            guard++;
        }
        for (size_t i = chain.size(); i > 0; i--) { m.order.push_back(chain[i - 1]); }
    }

    const Json* animations = doc.get("animations");
    for (size_t a = 0; animations && a < animations->size(); a++) {
        const Json& an = animations->at(a);
        Clip clip;
        const Json* name = an.get("name");
        clip.name = name && !name->text.empty() ? name->text : std::to_string(a);
        const Json* channels = an.get("channels");
        const Json* samplers = an.get("samplers");
        for (size_t c = 0; channels && samplers && c < channels->size(); c++) {
            const Json& ch = channels->at(c);
            const Json* target = ch.get("target");
            int sampler = ch.whole("sampler", -1);
            if (!target || sampler < 0 || size_t(sampler) >= samplers->size()) { continue; }
            Track t;
            t.joint = jointOf(target->whole("node", -1));
            const Json* path = target->get("path");
            std::string way = path ? path->text : "";
            t.path = way == "translation" ? 0 : way == "rotation" ? 1 : way == "scale" ? 2 : -1;
            if (t.joint < 0 || t.path < 0) { continue; }
            const Json& sm = samplers->at(size_t(sampler));
            const Json* how = sm.get("interpolation");
            std::string kind = how ? how->text : "LINEAR";
            t.how = kind == "STEP" ? 1 : kind == "CUBICSPLINE" ? 2 : 0;
            Column in = file.read(sm.whole("input", -1)), out = file.read(sm.whole("output", -1));
            int width = t.path == 1 ? 4 : 3;
            size_t keys = in.values.size(), need = keys * size_t(width) * (t.how == 2 ? 3 : 1);
            if (!in.ok || !out.ok || in.wide != 1 || out.wide != width || keys == 0 || out.values.size() < need) {
                continue;
            }
            for (double v : in.values) { t.times.push_back(float(v)); }
            for (size_t i = 0; i < need; i++) { t.values.push_back(float(std::max(-1.0, out.values[i] / out.top))); }
            if (out.top == 1) {
                for (size_t i = 0; i < need; i++) { t.values[i] = float(out.values[i]); }
            }
            clip.length = std::max(clip.length, t.times.back());
            clip.tracks.push_back(std::move(t));
        }
        m.clips.push_back(std::move(clip));
    }
    m.ready = true;
    return true;
}

const Clip* Model::clipNamed(const std::string& name) const {
    if (name.empty()) { return nullptr; }
    for (const Clip& c : clips) {
        if (c.name == name) { return &c; }
    }
    return nullptr;
}

void Clip::pose(int joint, float at, float t[3], float r[4], float s[3]) const {
    for (const Track& k : tracks) {
        if (k.joint != joint) { continue; }
        int width = k.path == 1 ? 4 : 3;
        size_t keys = k.times.size();
        auto value = [&](size_t key, int c) {
            return k.how == 2 ? k.values[(key * 3 + 1) * size_t(width) + size_t(c)] : k.values[key * size_t(width) + size_t(c)];
        };
        float got[4];
        size_t i = 0;
        while (i + 1 < keys && k.times[i + 1] <= at) { i++; }
        if (keys == 1 || at <= k.times[0] || i + 1 >= keys) {
            size_t key = at <= k.times[0] ? 0 : i;
            for (int c = 0; c < width; c++) { got[c] = value(key, c); }
        } else {
            float span = k.times[i + 1] - k.times[i];
            float f = span > 0 ? (at - k.times[i]) / span : 0;
            if (k.how == 1) {
                for (int c = 0; c < width; c++) { got[c] = value(i, c); }
            } else if (k.how == 2) {
                float f2 = f * f, f3 = f2 * f;
                for (int c = 0; c < width; c++) {
                    float p0 = value(i, c), p1 = value(i + 1, c);
                    float m0 = span * k.values[(i * 3 + 2) * size_t(width) + size_t(c)];
                    float m1 = span * k.values[((i + 1) * 3) * size_t(width) + size_t(c)];
                    got[c] = (2 * f3 - 3 * f2 + 1) * p0 + (f3 - 2 * f2 + f) * m0 + (-2 * f3 + 3 * f2) * p1 + (f3 - f2) * m1;
                }
            } else if (k.path == 1) {
                // The shorter way round between two turns.
                float a[4], b[4], dot = 0;
                for (int c = 0; c < 4; c++) {
                    a[c] = value(i, c);
                    b[c] = value(i + 1, c);
                    dot += a[c] * b[c];
                }
                if (dot < 0) {
                    for (float& v : b) { v = -v; }
                    dot = -dot;
                }
                float wa = 1 - f, wb = f;
                if (dot < 0.9995f) {
                    float angle = std::acos(std::min(1.0f, dot)), sine = std::sin(angle);
                    wa = std::sin((1 - f) * angle) / sine;
                    wb = std::sin(f * angle) / sine;
                }
                for (int c = 0; c < 4; c++) { got[c] = wa * a[c] + wb * b[c]; }
            } else {
                for (int c = 0; c < width; c++) { got[c] = value(i, c) + (value(i + 1, c) - value(i, c)) * f; }
            }
        }
        if (k.path == 0) {
            for (int c = 0; c < 3; c++) { t[c] = got[c]; }
        } else if (k.path == 2) {
            for (int c = 0; c < 3; c++) { s[c] = got[c]; }
        } else {
            float len = std::sqrt(got[0] * got[0] + got[1] * got[1] + got[2] * got[2] + got[3] * got[3]);
            if (len > 0) {
                for (int c = 0; c < 4; c++) { r[c] = got[c] / len; }
            }
        }
    }
}

} // namespace hive
