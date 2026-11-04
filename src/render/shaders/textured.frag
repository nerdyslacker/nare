#version 450

layout(set = 0, binding = 0) uniform sampler2D tex;

layout(push_constant) uniform Push {
	vec4 color;
} push;

layout(location = 0) in vec2 v_uv;

layout(location = 0) out vec4 out_color;

void main() {
	out_color = texture(tex, v_uv) * push.color;
}
