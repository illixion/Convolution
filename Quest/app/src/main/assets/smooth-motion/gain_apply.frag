#version 300 es
/*
 AI HDR for video on the Quest: the GLES port of Vergence's GainGridPass
 (Metal, Sources/VergenceApple/Stereo/GainGridPass.swift). Each pixel's gain
 is the worker's 16x9x8 grid (VergenceCore GainGrid, the ai-hdr workload)
 read as a 3D texture at the pixel's own (u, v, Y'), linear filtering,
 clamped to the edge cells; Y' is BT.709 luma of the SDR code values.

 - The frame's mean gain (gain_mean.frag, read from the mean target's last
   mip level) sets the cap's scale: every log gain is multiplied by
   log2(cap) / log2(mean) when the mean is over the cap
   (GainGrid.cappedScale), then by the ramp's strength.
 - SDR is decoded with BT.1886's 2.4 power; the gain multiplies linear
   light in BT.709 primaries, 1.0 = SDR white; then BT.2020 primaries and
   SMPTE ST 2084 (PQ) with SDR white at 203 nits (BT.2408), into a 10-bit
   window surface whose colour space is BT.2020 PQ.
 */
precision highp float;
uniform sampler2D frame;
uniform highp sampler3D grid;
uniform sampler2D meanGain;
uniform float meanLevel;    // the mean target's last mip level
uniform float cap;          // the most the frame's average gain may reach (linear)
uniform float strength;     // the ramp, 0...1
uniform float whiteNits;
in vec2 uv;
out vec4 color;

float gainLog2(vec2 topDown, vec3 sdr) {
    float luma = dot(clamp(sdr, 0.0, 1.0), vec3(0.2126, 0.7152, 0.0722));
    return texture(grid, vec3(topDown, luma)).r;
}

vec3 pq(vec3 nits) {
    const float m1 = 0.1593017578125, m2 = 78.84375;
    const float c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    vec3 y = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(m1));
    return pow((c1 + c2 * y) / (1.0 + c3 * y), vec3(m2));
}

void main() {
    vec4 pixel = texture(frame, uv);
    float mean = textureLod(meanGain, vec2(0.5), meanLevel).r;
    float scale = cap <= 1.0 ? 0.0 : (mean <= cap ? 1.0 : log2(cap) / log2(mean));
    float gain = exp2(gainLog2(vec2(uv.x, 1.0 - uv.y), pixel.rgb) * scale * strength);
    vec3 linear709 = pow(clamp(pixel.rgb, 0.0, 1.0), vec3(2.4)) * gain;
    // BT.709 to BT.2020 primaries (ITU-R BT.2087), by columns as in the Metal.
    const mat3 toBT2020 = mat3(vec3(0.6274, 0.0691, 0.0164),
                               vec3(0.3293, 0.9195, 0.0880),
                               vec3(0.0433, 0.0114, 0.8956));
    color = vec4(pq(max(toBT2020 * linear709, 0.0) * whiteNits), 1.0);
}
