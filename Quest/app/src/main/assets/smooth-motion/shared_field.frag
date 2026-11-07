#version 300 es
/*
 Smooth Motion for true stereo, both in-between eyes from one motion field:
 the GLES port of Vergence's SharedFieldInterpolator (Metal,
 Sources/VergenceApple/Stereo/SharedFieldInterpolator.swift). Same maths,
 per output pixel, in top-down pixel coordinates as the Metal kernel works:

 - Left eye: RIFE's result. The stored pair is F0->1 and F1->0, so at time t
   frame 0 is read at x + t * F1->0 and frame 1 at x + (1 - t) * F0->1. At
   t = 1/2 that is the Metal pass exactly (F1/2->0 = F1->0 / 2 and
   F1/2->1 = F0->1 / 2). Other t, for a display faster than twice the film's
   rate, take the straight-line motion RIFE's flow reversal assumes.
 - The mask is frame 0's weight at 1/2; at t it becomes
   (1 - t) m / ((1 - t) m + t (1 - m)), which is m at 1/2, 1 at 0 and 0 at 1.
 - Right eye: the left eye's field read across the right-to-left disparity,
   mixed between the two real frames' at t.

 A 2D picture (the smooth-motion-2d workload, Vergence's `.mono` packing) is
 the left eye alone over the whole frame: eyeSize is the frame, eyeOffset
 lies past its right edge so no pixel is a right eye, and the disparity
 textures are bound but never read.

 Fields are sampled bilinearly with pixel centres at +1/2, clamped to the
 edge (F.interpolate(align_corners=False)); frames bilinearly, clamped to
 each eye's own pixel centres (RIFE's border padding). The frame textures
 are upright in GL's bottom-left convention, the fields top row first.
 */
precision highp float;
uniform sampler2D previousFrame;
uniform sampler2D currentFrame;
uniform sampler2D flow;          // RGBA16F: F0->1 x, y, F1->0 x, y, in stored pixels
uniform sampler2D mask;          // R16F: frame 0's weight at t = 1/2
uniform sampler2D disparity0;    // R16F: right->left, x only, stored pixels
uniform sampler2D disparity1;
uniform vec2 frameSize;          // pixels, both eyes
uniform vec2 eyeSize;
uniform vec2 eyeOffset;          // where the right eye starts: (w/2, 0) side by side, (0, h/2) top and bottom
uniform vec2 flowScale;          // stored flow pixels -> eye pixels
uniform float disparityScale;    // stored disparity pixels -> eye pixels
uniform float t;
out vec4 color;

vec4 readFrame(sampler2D frame, vec2 p) {
    return texture(frame, vec2(p.x / frameSize.x, 1.0 - p.y / frameSize.y));
}

void main() {
    vec2 position = vec2(gl_FragCoord.x - 0.5, frameSize.y - gl_FragCoord.y - 0.5);
    bool right = eyeOffset.y > 0.0 ? position.y >= eyeOffset.y : position.x >= eyeOffset.x;
    vec2 origin = right ? eyeOffset : vec2(0.0);
    vec2 x = position - origin;

    // Where this pixel's motion is read in the left eye's field.
    vec2 at = x;
    if (right) {
        vec2 duv = (x + 0.5) / eyeSize;
        float d = mix(texture(disparity0, duv).r, texture(disparity1, duv).r, t) * disparityScale;
        at.x = clamp(x.x + d, 0.0, eyeSize.x - 1.0);
    }
    vec2 fuv = (at + 0.5) / eyeSize;
    vec4 f = texture(flow, fuv);
    float m = clamp(texture(mask, fuv).r, 0.0, 1.0);
    vec2 f01 = f.xy * flowScale;
    vec2 f10 = f.zw * flowScale;
    vec2 ft0 = f10 * t;
    vec2 ft1 = f01 * (1.0 - t);
    float a = (1.0 - t) * m;
    float b = t * (1.0 - m);
    float w0 = a + b > 0.0 ? a / (a + b) : 1.0 - t;

    vec2 lo = origin + 0.5;
    vec2 hi = origin + eyeSize - 0.5;
    vec4 c0 = readFrame(previousFrame, clamp(origin + x + ft0 + 0.5, lo, hi));
    vec4 c1 = readFrame(currentFrame, clamp(origin + x + ft1 + 0.5, lo, hi));
    color = c0 * w0 + c1 * (1.0 - w0);
}
