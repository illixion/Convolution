#version 300 es
/*
 AI HDR, first step: the linear gain a sparse grid of the picture's pixels
 would get, before the cap (GainGridPass's gainGridSum). Drawn into a 64x32
 half-float target whose mipmap chain's last level is then the frame's mean
 gain, which gain_apply.frag reads, so nothing comes back to the CPU.
 */
precision highp float;
uniform sampler2D frame;          // the SDR picture, upright in GL's convention
uniform highp sampler3D grid;     // 16x9x8 log2 gain, x right, y down, z luma
in vec2 uv;
out vec4 color;

float gainLog2(vec2 topDown, vec3 sdr) {
    float luma = dot(clamp(sdr, 0.0, 1.0), vec3(0.2126, 0.7152, 0.0722));
    return texture(grid, vec3(topDown, luma)).r;
}

void main() {
    vec3 sdr = texture(frame, uv).rgb;
    color = vec4(exp2(gainLog2(vec2(uv.x, 1.0 - uv.y), sdr)));
}
