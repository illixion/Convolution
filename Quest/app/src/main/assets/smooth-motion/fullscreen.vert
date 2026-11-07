#version 300 es
// One triangle covering the target; uv is 0...1 with GL's bottom-left origin.
out vec2 uv;
void main() {
    vec2 corners[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
    vec2 p = corners[gl_VertexID];
    uv = p * 0.5 + 0.5;
    gl_Position = vec4(p, 0.0, 1.0);
}
