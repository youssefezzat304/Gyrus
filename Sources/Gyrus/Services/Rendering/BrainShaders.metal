#include <metal_stdlib>
using namespace metal;

struct Particle { float4 position; float4 normal; float4 appearance; };
struct Region { float4 positionPhase; float4 interaction; };
struct Uniforms {
    float4x4 model, view, projection;
    float4 cameraTime, viewport, appearance, accent, activity, transition;
    float4 bloom, background, emptyBackground, control;
    float4 sprite, hoverPoint, hoverStyle;
};
struct PointOut {
    float4 position [[position]];
    float size [[point_size]];
    float3 color;
    float intensity;
    float activation;
    float4 glyph;
};

struct DepthOut { float4 position [[position]]; float size [[point_size]]; };
vertex DepthOut corticalDepth(uint id [[vertex_id]], constant Particle *particles [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    Particle p = particles[id];
    float4 view = u.view * u.model * float4(p.position.xyz, 1);
    bool hidden = p.position.w > 0.5f || view.z > -0.015f;
    return { hidden ? float4(2, 2, 2, 1) : u.projection * view,
             clamp(5.0f * u.viewport.z * u.viewport.w / max(0.02f, -view.z), 1.0f, 80.0f) };
}

vertex PointOut brainParticle(uint id [[vertex_id]], constant Particle *particles [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]], constant Region *regions [[buffer(2)]],
                              depth2d<float> cortex [[texture(0)]]) {
    Particle p = particles[id];
    float3 world = (u.model * float4(p.position.xyz, 1)).xyz;
    float4 view = u.view * float4(world, 1);
    float depth = -view.z;
    float3 normal = normalize((u.model * float4(p.normal.xyz, 0)).xyz);
    float facing = max(0.0f, dot(normal, normalize(u.cameraTime.xyz - world)));
    float depthLight = exp(-max(0.0f, depth - (u.viewport.w - 0.9f)) * u.appearance.y);
    float relief = 0.20f + 0.80f * max(0.0f, dot(normal, normalize(float3(-0.45f, 0.65f, 1))));
    float light = (0.015f + 0.985f * facing) * relief * pow(p.normal.w, u.background.w);
    float4 clip = u.projection * view;
    float2 screen = float2(clip.x / clip.w * 0.5f + 0.5f, 0.5f - clip.y / clip.w * 0.5f);
    constexpr sampler closest(filter::nearest, address::clamp_to_edge);
    float frontZ = cortex.sample(closest, screen, level(0));
    float near = u.control.y, far = u.control.z;
    float frontDepth = near * far / max(0.00001f, far - frontZ * (far - near));
    float opticalVisibility = 0.004f + 0.996f * exp(-max(0.0f, depth - frontDepth - 0.018f) * u.control.w);
    light *= opticalVisibility;
    // As we enter, the light comes from the volume rather than an external surface.
    light = mix(light * depthLight, 0.62f, smoothstep(0.40f, 0.73f, u.activity.w));
    float influence = 0, boost = 1;
    for (uint i = 0; i < uint(u.control.x); ++i) {
        Region r = regions[i];
        float selected = (int(i) == int(u.transition.y)) ? u.transition.x : 0.0f;
        float radius = u.accent.w * (1 + r.interaction.x * u.activity.z + selected * 0.45f);
        float3 delta = p.position.xyz - r.positionPhase.xyz;
        // Small coherent distortions prevent a circular activation boundary.
        float organic = 1 + 0.12f * sin(p.position.x * 37 + p.position.y * 23) * cos(p.position.z * 29);
        float local = exp(-dot(delta, delta) * organic / (radius * radius * 0.65f));
        float pulse = 1 + u.activity.x * sin(u.cameraTime.w * (1.55f + i * 0.055f) + r.positionPhase.w);
        float dominance = u.transition.y >= 0 && int(i) != int(u.transition.y) ? mix(1.0f, 0.35f, u.transition.x) : 1.0f;
        local *= dominance;
        influence = max(influence, local);
        boost = max(boost, 1 + local * u.activity.y * pulse * (1 + r.interaction.x * 0.25f + selected * 1.4f));
    }
    bool center = p.position.w > 2.5f;
    if (center) {
        int i = int(p.appearance.w);
        float selected = i == int(u.transition.y) ? u.transition.x : 0;
        influence = 1;
        light = max(light, 0.68f * opticalVisibility * smoothstep(0.04f, 0.3f, facing));
        boost = 1.8f + selected * 2.0f + regions[i].interaction.x * 0.35f;
    }
    // Inactive particles are neutral white. Every active particle uses exactly one accent hue.
    bool active = influence > 0.20f;
    float3 color = active ? pow(u.accent.xyz, float3(u.emptyBackground.w)) : float3(1);
    float shimmer = p.appearance.w < u.appearance.z && !center
        ? 1 + u.appearance.w * sin(u.cameraTime.w * (0.4f + p.appearance.w * 8) + p.appearance.z) : 1;
    float fade = mix(u.transition.z, u.transition.w, influence);
    float density = mix(1.0f, 0.055f, smoothstep(0.70f, 0.99f, u.activity.w));
    bool hidden = depth < 0.015f || (!center && p.appearance.w > density) || u.activity.w >= 1;
    PointOut out;
    out.position = hidden ? float4(2, 2, 2, 1) : u.projection * view;
    float magnification = clamp(u.viewport.w / max(depth, 0.02f), 0.55f, 28.0f);
    float diameter = p.appearance.x * u.sprite.x * magnification;
    if (u.hoverPoint.w > 0.001f) {
        float4 hoverView = u.view * u.model * float4(u.hoverPoint.xyz, 1);
        float4 hoverClip = u.projection * hoverView;
        float2 hoverScreen = float2(hoverClip.x / hoverClip.w * 0.5f + 0.5f,
                                   0.5f - hoverClip.y / hoverClip.w * 0.5f);
        float distance = length((screen - hoverScreen) * u.viewport.xy / u.viewport.z);
        float falloff = 1 - smoothstep(0.0f, u.hoverStyle.y, distance);
        // Nearby points on the far side of the brain must not grow through the surface.
        float depthFalloff = 1 - smoothstep(0.04f, u.sprite.y, abs(depth + hoverView.z));
        float neighbor = min(u.hoverStyle.w, diameter + (u.hoverStyle.w - diameter) * falloff);
        float target = int(id) == int(u.hoverStyle.x) ? u.hoverStyle.z : max(diameter, neighbor);
        float weight = int(id) == int(u.hoverStyle.x) ? u.hoverPoint.w
            : u.hoverPoint.w * depthFalloff * smoothstep(0.04f, 0.25f, facing);
        diameter = mix(diameter, target, weight);
    }
    out.size = clamp(diameter * u.viewport.z, 1.0f, 180.0f);
    out.color = color;
    out.intensity = hidden ? 0 : p.appearance.y * u.appearance.x * light * boost * shimmer * fade;
    out.activation = active ? influence : 0;
    out.glyph = float4(cos(p.appearance.z), sin(p.appearance.z), u.sprite.z, u.sprite.w);
    return out;
}

fragment half4 particleLight(PointOut in [[stage_in]], float2 uv [[point_coord]]) {
    float2 p = uv * 2 - 1;
    float r2 = dot(p, p);
    if (r2 > 1) discard_fragment();
    // Restore the original lightly filled, outlined triangles and seeded orientations.
    float2 q = float2(p.x * in.glyph.x - p.y * in.glyph.y, p.x * in.glyph.y + p.y * in.glyph.x);
    float distance = max(q.y - 0.39f, max(dot(q, float2(0.866025f, -0.5f)) - 0.39f,
                                        dot(q, float2(-0.866025f, -0.5f)) - 0.39f));
    float aa = max(fwidth(distance), 0.018f);
    float inside = 1 - smoothstep(-aa, aa, distance);
    float outline = 1 - smoothstep(0.035f, 0.035f + aa, abs(distance));
    float triangle = inside * in.glyph.z + outline * in.glyph.w;
    float halo = exp(-abs(distance) * 16) * (0.018f + in.activation * 0.045f);
    float3 light = in.color * (triangle + halo) * in.intensity * (1 - smoothstep(0.8f, 1.0f, r2));
    return half4(half3(light), 1);
}

kernel void extractBloom(texture2d<half, access::read> scene [[texture(0)]],
                         texture2d<half, access::write> output [[texture(1)]],
                         constant Uniforms &u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float3 sum = 0;
    for (uint y = 0; y < 4; ++y) for (uint x = 0; x < 4; ++x) {
        uint2 p = min(gid * 4 + uint2(x, y), uint2(scene.get_width()-1, scene.get_height()-1));
        float3 c = float3(scene.read(p).rgb);
        float peak = max(c.r, max(c.g, c.b));
        sum += c * max(0.0f, peak - u.bloom.y) / max(peak, 0.001f);
    }
    output.write(half4(half3(sum / 16), 1), gid);
}

struct ScreenOut { float4 position [[position]]; float2 uv; };
vertex ScreenOut screenTriangle(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y) };
}

fragment half4 compositeBrain(ScreenOut in [[stage_in]], texture2d<half> scene [[texture(0)]],
                             texture2d<half> glow [[texture(1)]], constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler sample(filter::linear, address::clamp_to_edge);
    float2 center = (in.uv - float2(0.5f, 0.46f)) * float2(u.viewport.x / u.viewport.y, 1);
    float illumination = exp(-dot(center, center) * 6) * u.bloom.w * (1 - u.activity.w);
    float3 background = mix(u.background.xyz, u.emptyBackground.xyz, smoothstep(0.60f, 1.0f, u.activity.w));
    float3 light = float3(scene.sample(sample, in.uv).rgb)
        + float3(glow.sample(sample, in.uv).rgb) * u.bloom.x;
    float3 mapped = pow(1 - exp(-light * u.bloom.z), float3(1.0f / u.emptyBackground.w));
    return half4(half3(background + illumination + mapped), 1);
}
