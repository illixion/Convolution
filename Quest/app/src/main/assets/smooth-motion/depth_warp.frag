#version 300 es
/*
 AI 3D's mesh warp, one eye's fragments: videoStereoMeshFragment's edge fill
 without the tonal adjustments (the Quest player has none). A fragment in a
 cell stretched over a strip a near subject uncovers takes the source pixel
 beyond the outline, on the far side, so the strip repeats the background
 beside it instead of smearing the outline across it.
 */
precision highp float;
uniform sampler2D frame;       // upright in GL's convention
uniform sampler2D depthMap;
uniform float edgeFill;        // 1: fill uncovered strips
in vec2 sourceUV;
in float stretch;
out vec4 color;

vec2 fillEdge(vec2 tc) {
    float fill = smoothstep(1.2, 1.8, stretch);
    if (fill <= 0.0) return tc;
    const float reach = 2.0 / 769.0;
    vec2 leftUV = vec2(max(tc.x - reach, 0.0), tc.y);
    vec2 rightUV = vec2(min(tc.x + reach, 1.0), tc.y);
    float depthLeft = textureLod(depthMap, leftUV, 0.0).r;
    float depthRight = textureLod(depthMap, rightUV, 0.0).r;
    return mix(tc, depthLeft < depthRight ? leftUV : rightUV, fill);
}

void main() {
    vec2 tc = edgeFill > 0.5 ? fillEdge(sourceUV) : sourceUV;
    color = vec4(texture(frame, vec2(tc.x, 1.0 - tc.y)).rgb, 1.0);
}
