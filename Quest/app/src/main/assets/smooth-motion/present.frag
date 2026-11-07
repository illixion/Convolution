#version 300 es
// A real frame, as it is.
precision mediump float;
uniform sampler2D frame;
in vec2 uv;
out vec4 color;
void main() {
    color = texture(frame, uv);
}
