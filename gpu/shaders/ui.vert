#version 450
// Baldr UI vertex shader: one vertex format for every draw kind. Positions are
// device pixels (origin top-left, y down); the push constant is the viewport
// size in pixels. Vulkan NDC also has y down, so no flip is needed.

layout(location = 0) in vec2  in_pos;
layout(location = 1) in vec2  in_uv;
layout(location = 2) in vec4  in_color;
layout(location = 3) in vec4  in_rect;      // x, y, w, h (px)
layout(location = 4) in float in_radius;
layout(location = 5) in float in_border_w;
layout(location = 6) in vec4  in_border;
layout(location = 7) in uint  in_kind;      // 0 = SDF quad, 1 = alpha glyph, 2 = RGBA glyph, 3 = shadow, 4 = backdrop, 5 = image, 6 = glow, 7 = highlight, 8 = line

layout(push_constant) uniform PC { vec2 viewport; } pc;

layout(location = 0)      out vec2  v_pos;
layout(location = 1)      out vec2  v_uv;
layout(location = 2)      out vec4  v_color;
layout(location = 3)      out vec4  v_rect;
layout(location = 4)      out vec2  v_params;   // radius, border_w
layout(location = 5)      out vec4  v_border;
layout(location = 6) flat out uint  v_kind;

void main() {
    gl_Position = vec4(in_pos / pc.viewport * 2.0 - 1.0, 0.0, 1.0);
    v_pos    = in_pos;
    v_uv     = in_uv;
    v_color  = in_color;
    v_rect   = in_rect;
    v_params = vec2(in_radius, in_border_w);
    v_border = in_border;
    v_kind   = in_kind;
}
