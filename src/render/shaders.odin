package render

// GLSL 330 core. Attribute and matrix names follow raylib's defaults so that
// DrawMesh() binds them automatically.

WOOD_VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
uniform mat4 lightVP;
out vec3 fragPos;
out vec3 fragNormal;
out vec2 fragUV;
out vec4 fragLight;
out vec3 localPos;
void main() {
    vec4 wp = matModel * vec4(vertexPosition, 1.0);
    fragPos = wp.xyz;
    fragNormal = normalize((matNormal * vec4(vertexNormal, 0.0)).xyz);
    fragUV = vertexTexCoord;
    fragLight = lightVP * wp;
    localPos = vertexPosition;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

SHADOW_FN :: `
uniform sampler2D shadowMap;
uniform vec2 shadowTexel;
float shadowFactor(vec4 lp, float ndl, float spread) {
    vec3 p = lp.xyz / lp.w * 0.5 + 0.5;
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
    float bias = max(0.0012 * (1.0 - ndl), 0.0004);
    // 8-tap rotated disk: soft enough, a third of the cost of a 5x5 grid
    const vec2 taps[8] = vec2[](vec2(-0.94, -0.34), vec2(0.95, -0.25), vec2(-0.09, -0.93), vec2(0.34, 0.94),
                                vec2(-0.82, 0.54), vec2(0.70, 0.66), vec2(0.20, -0.36), vec2(-0.32, 0.18));
    float lit = 0.0;
    for (int i = 0; i < 8; i++) {
        float d = texture(shadowMap, p.xy + taps[i] * 1.8 * shadowTexel * spread).r;
        lit += (p.z - bias > d) ? 0.0 : 1.0;
    }
    return lit / 8.0;
}
`

WOOD_FS :: `#version 330
in vec3 fragPos;
in vec3 fragNormal;
in vec2 fragUV;
in vec4 fragLight;
in vec3 localPos;
uniform vec4 colDiffuse;
uniform vec3 lightDir;
uniform vec3 viewPos;
uniform int matKind;      // 0 wood, 1 painted, 2 metal
uniform float grainRot;
uniform float seed;
uniform vec4 tint;        // rgb + amount (hover / error)
out vec4 finalColor;
` + SHADOW_FN + `
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * noise(p); p *= 2.03; a *= 0.5; }
    return v;
}
vec3 toLinear(vec3 c) { return pow(c, vec3(2.2)); }
void main() {
    vec3 N = normalize(fragNormal);
    if (!gl_FrontFacing) N = -N;
    vec3 base = toLinear(colDiffuse.rgb);
    vec2 uv = fragUV * 600.0;                 // back to millimetres
    if (grainRot > 0.5) uv = uv.yx;
    uv += vec2(seed * 137.0, seed * 59.0);
    float rough = 0.6;
    float specAmt = 0.08;
    if (matKind == 0) {
        // long fibres along u, rings warped by low-frequency noise
        float warp = fbm(vec2(uv.x * 0.004, uv.y * 0.02)) * 6.0;
        float rings = sin((uv.y * 0.11 + warp) * 3.14159);
        float fine = fbm(vec2(uv.x * 0.02, uv.y * 0.9));
        float g = smoothstep(-0.3, 1.0, rings) * 0.55 + fine * 0.45;
        base *= mix(0.78, 1.08, g);
        rough = 0.55;
        specAmt = 0.06;
    } else if (matKind == 1) {
        base *= 0.98 + 0.02 * noise(uv * 0.5);
        rough = 0.45;
        specAmt = 0.10;
    } else {
        base *= 0.92 + 0.08 * fbm(vec2(uv.x * 0.05, uv.y * 2.0));
        rough = 0.3;
        specAmt = 0.35;
    }
    vec3 L = normalize(-lightDir);
    vec3 V = normalize(viewPos - fragPos);
    vec3 H = normalize(L + V);
    float ndl = max(dot(N, L), 0.0);
    float sh = shadowFactor(fragLight, ndl, 1.0);
    vec3 sky = vec3(0.86, 0.90, 0.97);
    vec3 gnd = vec3(0.50, 0.46, 0.42);
    vec3 amb = mix(gnd, sky, N.y * 0.5 + 0.5) * 0.62;
    float shininess = mix(16.0, 96.0, 1.0 - rough);
    float spec = pow(max(dot(N, H), 0.0), shininess) * specAmt * sh;
    float fres = pow(1.0 - max(dot(N, V), 0.0), 4.0) * 0.08;
    vec3 sun = vec3(1.0, 0.96, 0.90) * 1.05;
    vec3 col = base * (amb + sun * ndl * sh) + vec3(spec) + vec3(fres) * sky;
    col = mix(col, toLinear(tint.rgb), tint.a);
    col = col / (1.0 + col * 0.12);
    finalColor = vec4(pow(col, vec3(1.0 / 2.2)), 1.0);
}
`

DEPTH_VS :: `#version 330
in vec3 vertexPosition;
uniform mat4 mvp;
void main() { gl_Position = mvp * vec4(vertexPosition, 1.0); }
`

DEPTH_FS :: `#version 330
out vec4 finalColor;
void main() { finalColor = vec4(1.0); }
`

FLAT_FS :: `#version 330
uniform vec4 colDiffuse;
out vec4 finalColor;
void main() { finalColor = colDiffuse; }
`

GROUND_VS :: `#version 330
in vec3 vertexPosition;
uniform mat4 mvp;
out vec3 worldPos;
void main() {
    worldPos = vertexPosition;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`

GROUND_FS :: `#version 330
in vec3 worldPos;
uniform mat4 lightVP;
uniform sampler2D contactMap;
uniform mat4 contactVP;
uniform vec3 contactRange;  // near, far, camera y
uniform vec3 viewPos;
uniform vec3 groundColor;
uniform vec3 fadeColor;
uniform float fadeRadius;
uniform vec2 sceneCenter;
uniform float showGrid;
out vec4 finalColor;
` + SHADOW_FN + `
float gridLine(vec2 p, float spacing, float width) {
    vec2 g = abs(fract(p / spacing - 0.5) - 0.5) * spacing;
    vec2 w = fwidth(p) * width;
    vec2 l = 1.0 - smoothstep(vec2(0.0), w, g);
    return max(l.x, l.y);
}
float heightAt(vec2 xz) {
    vec4 cp = contactVP * vec4(xz.x, 0.0, xz.y, 1.0);
    vec2 uv = cp.xy / cp.w * 0.5 + 0.5;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1e9;
    float d = texture(contactMap, uv).r;
    if (d >= 0.9999) return 1e9;
    return contactRange.x + d * (contactRange.y - contactRange.x) + contactRange.z;
}
void main() {
    vec2 xz = worldPos.xz;
    // soft contact shadow from the lowest surfaces above the floor
    float occ = 0.0;
    const int N = 10;
    for (int i = 0; i < N; i++) {
        float a = float(i) * 2.39996;
        float r = sqrt(float(i) + 0.5) / sqrt(float(N)) * 70.0;
        float h = heightAt(xz + vec2(cos(a), sin(a)) * r);
        occ += 1.0 - smoothstep(0.0, 220.0, h);
    }
    float hc = heightAt(xz);
    float ao = 1.0 - 0.55 * (occ / float(N)) - 0.25 * (1.0 - smoothstep(0.0, 25.0, hc));
    float sh = shadowFactor(lightVP * vec4(worldPos, 1.0), 1.0, 2.0);
    vec3 col = groundColor * (0.72 + 0.28 * sh) * clamp(ao, 0.0, 1.0);
    if (showGrid > 0.5) {
        float minor = gridLine(xz, 100.0, 1.0);
        float major = gridLine(xz, 1000.0, 1.4);
        float dist = length(viewPos - worldPos);
        float fadeMinor = 1.0 - smoothstep(2500.0, 9000.0, dist);
        col = mix(col, col * 0.86, minor * 0.6 * fadeMinor);
        col = mix(col, col * 0.74, major * 0.8);
        float axisX = 1.0 - smoothstep(0.0, fwidth(worldPos.z) * 1.5, abs(worldPos.z));
        float axisZ = 1.0 - smoothstep(0.0, fwidth(worldPos.x) * 1.5, abs(worldPos.x));
        col = mix(col, vec3(0.86, 0.36, 0.33), axisX * 0.55);
        col = mix(col, vec3(0.33, 0.52, 0.86), axisZ * 0.55);
    }
    float fade = smoothstep(fadeRadius * 0.45, fadeRadius, length(xz - sceneCenter));
    finalColor = vec4(mix(col, fadeColor, fade), 1.0 - fade);
}
`

OUTLINE_FS :: `#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec2 texel;
uniform float radius;
uniform vec4 selColor;
uniform vec4 hoverColor;
out vec4 finalColor;
void main() {
    vec4 c = texture(texture0, fragTexCoord);
    float sel = 0.0, hov = 0.0;
    const vec2 dirs[8] = vec2[](vec2(1, 0), vec2(0.707, 0.707), vec2(0, 1), vec2(-0.707, 0.707),
                                vec2(-1, 0), vec2(-0.707, -0.707), vec2(0, -1), vec2(0.707, -0.707));
    for (int i = 0; i < 8; i++) {
        vec4 s = texture(texture0, fragTexCoord + dirs[i] * radius * texel);
        sel = max(sel, s.r);
        hov = max(hov, s.g);
    }
    float aSel = sel * (1.0 - c.r) * selColor.a;
    float aHov = hov * (1.0 - c.g) * (1.0 - sel) * hoverColor.a;
    float aFill = c.r * 0.10;
    float a = max(max(aSel, aHov), aFill);
    vec3 rgb = (aHov > aSel && aHov > aFill) ? hoverColor.rgb : selColor.rgb;
    finalColor = vec4(rgb, a);
}
`
