#version 450

layout(push_constant) uniform Push {
	vec4 color;
} push;

layout(location = 0) out vec4 out_color;

void main() {
	out_color = push.color;
}
