#include "shapes.h"

#include <cmath>
#include <cstdlib>
#include <functional>

namespace hive {

namespace {

const float PI = 3.14159265358979323846f;

float sign(float v) { return v > 0 ? 1.0f : (v < 0 ? -1.0f : 0.0f); }

void push3(std::vector<float>& into, float x, float y, float z) {
    into.push_back(x);
    into.push_back(y);
    into.push_back(z);
}

typedef std::function<void(float, float, float, float*, float*)> Along;

void spans(Mesh& m, const Along& along) {
    size_t n = m.count();
    m.spanU.assign(n * 3, 0);
    m.spanV.assign(n * 3, 0);
    m.rounding.assign(n, 0);
    for (size_t i = 0; i < n; i++) {
        along(m.facing[i * 3], m.facing[i * 3 + 1], m.facing[i * 3 + 2], &m.spanU[i * 3], &m.spanV[i * 3]);
    }
}

// +X is laid out by -Z and Y, -X by Z and Y, +Y by X and -Z, -Y by X and Z, +Z by X and Y, -Z by -X and Y.
void faces(float x, float y, float z, float* u, float* v) {
    if (std::fabs(x) > 0.5f) {
        u[2] = -sign(x);
        v[1] = 1;
    } else if (std::fabs(y) > 0.5f) {
        u[0] = 1;
        v[2] = -sign(y);
    } else {
        u[0] = sign(z);
        v[1] = 1;
    }
}

void globe(float, float, float, float* u, float* v) {
    u[0] = 2 * PI;
    v[1] = PI;
}

void drum(float, float y, float, float* u, float* v) {
    if (std::fabs(y) > 0.99f) {
        u[0] = 2;
        v[2] = 2;
    } else {
        u[0] = 2 * PI;
        v[1] = 1;
    }
}

void ridge(float, float, float z, float* u, float* v) {
    u[0] = 1;
    if (std::fabs(z) > 0.99f) { v[1] = 1; }
    else { v[2] = 1; }
}

void floorSpan(float, float, float, float* u, float* v) {
    u[0] = 2.0f / 3.0f;
    v[2] = 2.0f / 3.0f;
}

void plane(Mesh& m, int u, int v, int w, float udir, float vdir, float width, float height, float depth,
        int gridX, int gridY) {
    float segW = width / float(gridX), segH = height / float(gridY);
    float halfW = width / 2, halfH = height / 2, halfD = depth / 2;
    uint32_t first = uint32_t(m.count());
    for (int iy = 0; iy <= gridY; iy++) {
        float y = float(iy) * segH - halfH;
        for (int ix = 0; ix <= gridX; ix++) {
            float x = float(ix) * segW - halfW;
            float p[3] = {0, 0, 0}, n[3] = {0, 0, 0};
            p[u] = x * udir;
            p[v] = y * vdir;
            p[w] = halfD;
            n[w] = depth > 0 ? 1.0f : -1.0f;
            push3(m.place, p[0], p[1], p[2]);
            push3(m.facing, n[0], n[1], n[2]);
            m.uv.push_back(float(ix) / float(gridX));
            m.uv.push_back(1 - float(iy) / float(gridY));
        }
    }
    int gridX1 = gridX + 1;
    for (int iy = 0; iy < gridY; iy++) {
        for (int ix = 0; ix < gridX; ix++) {
            uint32_t a = first + uint32_t(ix + gridX1 * iy);
            uint32_t b = first + uint32_t(ix + gridX1 * (iy + 1));
            uint32_t c = first + uint32_t((ix + 1) + gridX1 * (iy + 1));
            uint32_t d = first + uint32_t((ix + 1) + gridX1 * iy);
            m.index.insert(m.index.end(), {a, b, d, b, c, d});
        }
    }
}

Mesh box(int cuts) {
    Mesh m;
    plane(m, 2, 1, 0, -1, -1, 1, 1, 1, cuts, cuts);
    plane(m, 2, 1, 0, 1, -1, 1, 1, -1, cuts, cuts);
    plane(m, 0, 2, 1, 1, 1, 1, 1, 1, cuts, cuts);
    plane(m, 0, 2, 1, 1, -1, 1, 1, -1, cuts, cuts);
    plane(m, 0, 1, 2, 1, -1, 1, 1, 1, cuts, cuts);
    plane(m, 0, 1, 2, -1, -1, 1, 1, -1, cuts, cuts);
    return m;
}

// A bevel built in would stretch with the shape: a vertex says which corner it is, and the shader rounds it.
Mesh roundedBox() {
    Mesh m = box(3);
    spans(m, faces);
    size_t n = m.count();
    m.along.assign(n * 4, 0);
    for (size_t i = 0; i < n; i++) {
        float* p = &m.place[i * 3];
        float* f = &m.facing[i * 3];
        const float* u = &m.spanU[i * 3];
        const float* v = &m.spanV[i * 3];
        float cx = f[1] * u[2] - f[2] * u[1], cy = f[2] * u[0] - f[0] * u[2], cz = f[0] * u[1] - f[1] * u[0];
        float hand = cx * v[0] + cy * v[1] + cz * v[2] < 0 ? -1.0f : 1.0f;
        m.along[i * 4] = u[0];
        m.along[i * 4 + 1] = u[1];
        m.along[i * 4 + 2] = u[2];
        m.along[i * 4 + 3] = hand;
        float x = sign(p[0]), y = sign(p[1]), z = sign(p[2]);
        float vx = p[0] - x / 6, vy = p[1] - y / 6, vz = p[2] - z / 6;
        float len = std::sqrt(vx * vx + vy * vy + vz * vz);
        vx /= len;
        vy /= len;
        vz /= len;
        f[0] = vx;
        f[1] = vy;
        f[2] = vz;
        p[0] = x * 0.499f + vx * 0.001f;
        p[1] = y * 0.499f + vy * 0.001f;
        p[2] = z * 0.499f + vz * 0.001f;
        m.rounding[i] = 1;
    }
    return m;
}

Mesh roundedDrum() {
    Mesh m;
    const float rows[6][3] = {{0, 1, 1}, {0.7071068f, 0.7071068f, 1}, {1, 0, 1}, {1, 0, -1},
        {0.7071068f, -0.7071068f, -1}, {0, -1, -1}};
    auto put = [&](float out, float up, float side, float turn, float round, float u) {
        float sn = std::sin(turn), cs = std::cos(turn);
        float reach = (round == 3 && side == 0) ? 0 : 0.999f + out * 0.001f;
        float y = side == 0 ? up * 0.5f : side * 0.499f + up * 0.001f;
        push3(m.place, reach * sn, y, reach * cs);
        push3(m.facing, out * sn, up, out * cs);
        m.uv.push_back(u);
        m.uv.push_back(0);
        m.rounding.push_back(round);
        if (round == 2) {
            push3(m.spanU, 2 * PI, 0, 0);
            push3(m.spanV, 0, 1, 0);
            m.along.insert(m.along.end(), {cs, 0, -sn, 1});
        } else {
            push3(m.spanU, 2, 0, 0);
            push3(m.spanV, 0, 0, 2);
            m.along.insert(m.along.end(), {1, 0, 0, up > 0 ? -1.0f : 1.0f});
        }
    };
    for (int r = 0; r < 6; r++) {
        for (int k = 0; k <= 20; k++) {
            put(rows[r][0], rows[r][1], rows[r][2], float(k) / 20 * 2 * PI, 2, float(k) / 20);
        }
    }
    for (uint32_t r = 0; r < 5; r++) {
        for (uint32_t k = 0; k < 20; k++) {
            uint32_t a = r * 21 + k, b = a + 21;
            m.index.insert(m.index.end(), {a, b, a + 1, b, b + 1, a + 1});
        }
    }
    for (int end = 1; end >= -1; end -= 2) {
        uint32_t middle = uint32_t(m.count());
        put(0, float(end), 0, 0, 3, 0);
        for (int k = 0; k <= 20; k++) { put(0, float(end), float(end), float(k) / 20 * 2 * PI, 3, 0); }
        for (uint32_t k = 0; k < 20; k++) {
            if (end > 0) { m.index.insert(m.index.end(), {middle + 1 + k, middle + 2 + k, middle}); }
            else { m.index.insert(m.index.end(), {middle + 2 + k, middle + 1 + k, middle}); }
        }
    }
    return m;
}

Mesh sphere(int wide, int tall) {
    Mesh m;
    for (int iy = 0; iy <= tall; iy++) {
        float v = float(iy) / float(tall);
        float shift = 0;
        if (iy == 0) { shift = 0.5f / float(wide); }
        else if (iy == tall) { shift = -0.5f / float(wide); }
        for (int ix = 0; ix <= wide; ix++) {
            float u = float(ix) / float(wide);
            float x = -std::cos(u * 2 * PI) * std::sin(v * PI);
            float y = std::cos(v * PI);
            float z = std::sin(u * 2 * PI) * std::sin(v * PI);
            push3(m.place, x, y, z);
            float len = std::sqrt(x * x + y * y + z * z);
            if (len < 1e-6f) { push3(m.facing, 0, y > 0 ? 1.0f : -1.0f, 0); }
            else { push3(m.facing, x / len, y / len, z / len); }
            m.uv.push_back(u + shift);
            m.uv.push_back(1 - v);
        }
    }
    auto at = [&](int iy, int ix) { return uint32_t(iy * (wide + 1) + ix); };
    for (int iy = 0; iy < tall; iy++) {
        for (int ix = 0; ix < wide; ix++) {
            uint32_t a = at(iy, ix + 1), b = at(iy, ix), c = at(iy + 1, ix), d = at(iy + 1, ix + 1);
            if (iy != 0) { m.index.insert(m.index.end(), {a, b, d}); }
            if (iy != tall - 1) { m.index.insert(m.index.end(), {b, c, d}); }
        }
    }
    return m;
}

Mesh tube(float top, float bottom, float height, int around) {
    Mesh m;
    float half = height / 2, slope = (bottom - top) / height;
    for (int y = 0; y <= 1; y++) {
        float v = float(y);
        float radius = v * (bottom - top) + top;
        for (int x = 0; x <= around; x++) {
            float u = float(x) / float(around);
            float sn = std::sin(u * 2 * PI), cs = std::cos(u * 2 * PI);
            push3(m.place, radius * sn, -v * height + half, radius * cs);
            float len = std::sqrt(sn * sn + slope * slope + cs * cs);
            push3(m.facing, sn / len, slope / len, cs / len);
            m.uv.push_back(u);
            m.uv.push_back(1 - v);
        }
    }
    for (int x = 0; x < around; x++) {
        uint32_t a = uint32_t(x), b = uint32_t(around + 1 + x), c = uint32_t(around + 1 + x + 1), d = uint32_t(x + 1);
        if (top > 0) { m.index.insert(m.index.end(), {a, b, d}); }
        if (bottom > 0) { m.index.insert(m.index.end(), {b, c, d}); }
    }
    for (int end = 0; end < 2; end++) {
        bool up = end == 0;
        float radius = up ? top : bottom, way = up ? 1.0f : -1.0f;
        if (radius <= 0) { continue; }
        uint32_t centres = uint32_t(m.count());
        for (int x = 1; x <= around; x++) {
            push3(m.place, 0, half * way, 0);
            push3(m.facing, 0, way, 0);
            m.uv.push_back(0.5f);
            m.uv.push_back(0.5f);
        }
        uint32_t rim = uint32_t(m.count());
        for (int x = 0; x <= around; x++) {
            float u = float(x) / float(around);
            float sn = std::sin(u * 2 * PI), cs = std::cos(u * 2 * PI);
            push3(m.place, radius * sn, half * way, radius * cs);
            push3(m.facing, 0, way, 0);
            m.uv.push_back(cs * 0.5f + 0.5f);
            m.uv.push_back(sn * 0.5f * way + 0.5f);
        }
        for (uint32_t x = 0; x < uint32_t(around); x++) {
            uint32_t c = centres + x, i = rim + x;
            if (up) { m.index.insert(m.index.end(), {i, i + 1, c}); }
            else { m.index.insert(m.index.end(), {i + 1, i, c}); }
        }
    }
    return m;
}

Mesh gable() {
    Mesh m = tube(1, 1, 1, 3);
    size_t n = m.count();
    for (size_t i = 0; i < n; i++) {
        float* p = &m.place[i * 3];
        float* f = &m.facing[i * 3];
        float py = p[2], pz = -p[1];
        float fy = f[2], fz = -f[1];
        p[1] = py / 1.5f - 1.0f / 6.0f;
        p[2] = pz;
        p[0] = p[0] / 1.7320508f;
        // A normal goes through the inverse of the stretch.
        float nx = f[0] * 1.7320508f, ny = fy * 1.5f, nz = fz;
        float len = std::sqrt(nx * nx + ny * ny + nz * nz);
        f[0] = nx / len;
        f[1] = ny / len;
        f[2] = nz / len;
    }
    return m;
}

Mesh ground() {
    Mesh m;
    for (int iy = 0; iy <= 1; iy++) {
        for (int ix = 0; ix <= 1; ix++) {
            push3(m.place, float(ix) - 0.5f, 0, float(iy) - 0.5f);
            push3(m.facing, 0, 1, 0);
            m.uv.push_back(float(ix));
            m.uv.push_back(1 - float(iy));
        }
    }
    m.index = {0, 2, 1, 2, 3, 1};
    return m;
}

} // namespace

void directions(Mesh& m) {
    size_t n = m.count();
    std::vector<float> tan(n * 3, 0), bit(n * 3, 0);
    for (size_t t = 0; t + 2 < m.index.size(); t += 3) {
        uint32_t i0 = m.index[t], i1 = m.index[t + 1], i2 = m.index[t + 2];
        const float* p0 = &m.place[i0 * 3];
        const float* p1 = &m.place[i1 * 3];
        const float* p2 = &m.place[i2 * 3];
        float e1[3] = {p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]};
        float e2[3] = {p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]};
        float du1 = m.uv[i1 * 2] - m.uv[i0 * 2], dv1 = m.uv[i1 * 2 + 1] - m.uv[i0 * 2 + 1];
        float du2 = m.uv[i2 * 2] - m.uv[i0 * 2], dv2 = m.uv[i2 * 2 + 1] - m.uv[i0 * 2 + 1];
        float det = du1 * dv2 - du2 * dv1;
        if (std::fabs(det) < 1e-12f) { continue; }
        float r = 1 / det;
        for (int k = 0; k < 3; k++) {
            float tk = (e1[k] * dv2 - e2[k] * dv1) * r;
            float bk = (e2[k] * du1 - e1[k] * du2) * r;
            tan[i0 * 3 + k] += tk;
            tan[i1 * 3 + k] += tk;
            tan[i2 * 3 + k] += tk;
            bit[i0 * 3 + k] += bk;
            bit[i1 * 3 + k] += bk;
            bit[i2 * 3 + k] += bk;
        }
    }
    m.along.assign(n * 4, 0);
    for (size_t i = 0; i < n; i++) {
        const float* f = &m.facing[i * 3];
        float* t = &tan[i * 3];
        float d = f[0] * t[0] + f[1] * t[1] + f[2] * t[2];
        float x = t[0] - f[0] * d, y = t[1] - f[1] * d, z = t[2] - f[2] * d;
        float len = std::sqrt(x * x + y * y + z * z);
        if (len < 1e-6f) {
            float ax = std::fabs(f[0]) < 0.9f ? 1.0f : 0.0f, ay = ax > 0 ? 0.0f : 1.0f;
            x = ay * f[2];
            y = -ax * f[2];
            z = ax * f[1] - ay * f[0];
            len = std::sqrt(x * x + y * y + z * z);
            if (len < 1e-6f) {
                x = 1;
                y = 0;
                z = 0;
                len = 1;
            }
        }
        x /= len;
        y /= len;
        z /= len;
        float cx = f[1] * z - f[2] * y, cy = f[2] * x - f[0] * z, cz = f[0] * y - f[1] * x;
        const float* b = &bit[i * 3];
        m.along[i * 4] = x;
        m.along[i * 4 + 1] = y;
        m.along[i * 4 + 2] = z;
        m.along[i * 4 + 3] = cx * b[0] + cy * b[1] + cz * b[2] < 0 ? -1.0f : 1.0f;
    }
}

Mesh unitMesh(const std::string& form) {
    if (form == "sphere") {
        Mesh m = sphere(16, 11);
        spans(m, globe);
        directions(m);
        return m;
    }
    if (form == "cylinder") { return roundedDrum(); }
    if (form.compare(0, 5, "cone|") == 0) {
        size_t bar = form.find('|', 5);
        float top = float(atoi(form.substr(5, bar - 5).c_str())) / 32.0f;
        float bottom = float(atoi(form.substr(bar + 1).c_str())) / 32.0f;
        Mesh m = tube(top, bottom, 1, 20);
        float widening = bottom - top;
        // A cone's side is measured down its slope: the difference in radius rides in its second span.
        spans(m, [widening](float x, float y, float z, float* u, float* v) {
            drum(x, y, z, u, v);
            v[0] = widening;
        });
        directions(m);
        return m;
    }
    if (form == "roof") {
        Mesh m = gable();
        spans(m, ridge);
        directions(m);
        return m;
    }
    if (form == "ground") {
        Mesh m = ground();
        spans(m, floorSpan);
        directions(m);
        return m;
    }
    return roundedBox();
}

} // namespace hive
