#version 300 es
/*
 AI 3D's depth-displaced mesh, one eye: the GLES port of Vergence's
 videoStereoMeshVertex (Metal, Sources/VergenceApple/Stereo/StereoShaders.metal).
 Each grid point shifts horizontally by its disparity, (depth - convergence)
 * strength, feathered to zero over the outer 5% of the width, and takes a
 Z from its depth so nearer geometry occludes farther under the depth test.
 Depth is the ai-3d-depth record's map, shot-space inverse depth (near = 1)
 = byte * valueScale + valueBias, through the depth budget's soft knees.

 The grid point comes from gl_VertexID (column i % columns, row i / columns),
 top row first like the depth map; the source frame is upright in GL's
 bottom-left convention, so its texture coordinate flips y.
 */
precision highp float;
uniform sampler2D depthMap;    // R8, top row first: the record's bytes
uniform vec2 gridSize;         // columns, rows
uniform float depthStrength;   // most horizontal disparity, a fraction of the width
uniform float convergence;     // depth on the window plane (1: nothing in front of it)
uniform float eyeSign;         // +1 left eye, -1 right
uniform float depthValueScale; // record scale * 255 (the texture reads byte / 255)
uniform float depthValueBias;  // record offset
uniform vec2 depthBudget;      // knees (DepthBudget.studio: 0.08, 0.7)
out vec2 sourceUV;             // top-down, as the Metal's texCoord
out float stretch;

float budget(float y, vec2 knees) {
    if (y > knees.y) {
        float w = 1.0 - knees.y;
        return w > 0.0 ? knees.y + w * tanh((y - knees.y) / w) : min(y, 1.0);
    }
    if (y < knees.x) {
        float w = knees.x;
        return w > 0.0 ? knees.x - w * tanh((knees.x - y) / w) : max(y, 0.0);
    }
    return y;
}

float edgeFeather(float x) {
    const float feather = 0.05;
    return smoothstep(0.0, feather, x) * (1.0 - smoothstep(1.0 - feather, 1.0, x));
}

float depthAt(vec2 grid) {
    return budget(textureLod(depthMap, grid, 0.0).r * depthValueScale + depthValueBias, depthBudget);
}

float disparityAt(vec2 grid) {
    return (depthAt(grid) - convergence) * depthStrength * edgeFeather(grid.x);
}

void main() {
    int columns = int(gridSize.x);
    vec2 grid = vec2(float(gl_VertexID % columns), float(gl_VertexID / columns)) / (gridSize - 1.0);
    float depth = depthAt(grid);
    float disparity = (depth - convergence) * depthStrength * edgeFeather(grid.x);
    gl_Position = vec4(grid.x * 2.0 - 1.0 + eyeSign * disparity * 2.0, 1.0 - grid.y * 2.0,
                       clamp(1.0 - depth, 0.0, 1.0) * 2.0 - 1.0, 1.0);
    sourceUV = grid;
    // Screen distance per unit of source distance across the cell, from the depth either side.
    const float h = 1.0 / 769.0;
    float left = disparityAt(vec2(max(grid.x - h, 0.0), grid.y));
    float right = disparityAt(vec2(min(grid.x + h, 1.0), grid.y));
    stretch = 1.0 + eyeSign * (right - left) / (2.0 * h);
}
