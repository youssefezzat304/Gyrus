#include <metal_stdlib>
using namespace metal;

struct TopicNode { float4 position; float4 appearance; };
struct TopicUniforms { float4x4 modelView; float4x4 projection; float4 viewport; float4 accent; };
struct TopicPoint {
    float4 position [[position]];
    float size [[point_size]];
    float2 orientation;
    float selected;
    float brightness;
};

vertex TopicPoint topicNode(uint id [[vertex_id]], constant TopicNode *nodes [[buffer(0)]],
                           constant TopicUniforms &u [[buffer(1)]]) {
    TopicNode node = nodes[id];
    float4 view = u.modelView * float4(node.position.xyz, 1);
    float magnification = clamp(7.8f / max(0.1f, -view.z), 0.6f, 2.0f);
    return {u.projection * view, node.appearance.x * u.viewport.z * magnification,
            float2(cos(node.appearance.y), sin(node.appearance.y)), node.appearance.z,
            1.5f * clamp(magnification, 0.65f, 1.25f)};
}

fragment half4 topicTriangle(TopicPoint in [[stage_in]], float2 uv [[point_coord]],
                            constant TopicUniforms &u [[buffer(0)]]) {
    float2 p = uv * 2 - 1;
    float r2 = dot(p, p);
    if (r2 > 1) discard_fragment();
    float2 q = float2(p.x * in.orientation.x - p.y * in.orientation.y,
                      p.x * in.orientation.y + p.y * in.orientation.x);
    float d = max(q.y - 0.39f, max(dot(q, float2(0.866025f, -0.5f)) - 0.39f,
                                 dot(q, float2(-0.866025f, -0.5f)) - 0.39f));
    float aa = max(fwidth(d), 0.018f);
    float fill = (1 - smoothstep(-aa, aa, d)) * 0.20f;
    float outline = (1 - smoothstep(0.035f, 0.035f + aa, abs(d))) * 0.80f;
    float halo = exp(-abs(d) * 10) * in.selected * 0.45f + exp(-r2 * 4) * in.selected * 0.07f;
    float3 color = mix(float3(1), pow(u.accent.xyz, float3(2.2f)), in.selected);
    float3 light = color * (fill + outline + halo) * in.brightness * (1 - smoothstep(0.82f, 1.0f, r2));
    return half4(half3(pow(1 - exp(-light * 1.15f), float3(1 / 2.2f))), 1);
}

struct TopicLine { float4 position; };
vertex float4 topicLine(uint id [[vertex_id]], constant TopicLine *vertices [[buffer(0)]],
                       constant TopicUniforms &u [[buffer(1)]]) {
    return u.projection * u.modelView * vertices[id].position;
}
fragment half4 topicLineLight() { return half4(0.459h, 0.424h, 1.0h, 0.32h); }
