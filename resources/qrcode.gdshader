shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

void fragment() {
	vec2 screen_size = 1.0 / SCREEN_PIXEL_SIZE;

	float side = min(screen_size.x, screen_size.y) * 0.75;

	vec2 half_size = (vec2(side, side) / screen_size) * 0.5;
	vec2 center = vec2(0.5, 0.5);

	if (
		abs(SCREEN_UV.x - center.x) <= half_size.x &&
		abs(SCREEN_UV.y - center.y) <= half_size.y
	) {
		discard;
	}

	vec3 blurred = textureLod(screen_texture, SCREEN_UV, 3.0).rgb;

	blurred *= 0.45;

	COLOR = vec4(blurred, 1.0);
}