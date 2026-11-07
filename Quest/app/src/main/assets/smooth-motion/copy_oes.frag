#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
// A decoded frame (the decoder's SurfaceTexture) copied upright into a frame
// texture, so the pass can read two frames while the decoder moves on.
precision mediump float;
uniform samplerExternalOES frame;
uniform mat4 textureTransform;
in vec2 uv;
out vec4 color;
void main() {
    color = texture(frame, (textureTransform * vec4(uv, 0.0, 1.0)).xy);
}
