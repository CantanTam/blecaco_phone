shader_type canvas_item;

// ============================================================
// 封面光晕：一个「比卡片大一圈」的圆角矩形，从卡片边缘向外渐隐
//
// ⚠️ 为什么不用 StyleBoxFlat 的 shadow：
//    Godot 的阴影是**方角**的，不跟 corner_radius 走，
//    会在卡片四角留下直角的绿色残留（实测确认）。
//    这里用圆角矩形的有符号距离（SDF）算，光晕才会真正贴着圆角规形走。
//
// 这个节点由 mode_select.gd 每帧对齐到「当前选中那张卡片」，
// 并写入 rect_size；其余参数来自 scripts/mode_cover_style.gd。
// ============================================================

// 光晕颜色 + 亮度（alpha 就是强度）
uniform vec4 glow_color : source_color = vec4(0.0, 1.0, 0.0, 0.7);

// 光晕向外扩散的厚度（px）
uniform float glow_size = 28.0;

// 内圈圆角半径，要和卡片的圆角一致（px）
uniform float corner_radius = 30.0;

// 本节点的像素尺寸（脚本每帧写入）
uniform vec2 rect_size = vec2(560.0, 720.0);

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

// 圆角矩形的有符号距离：负数在内部，正数是到边框的距离
float rounded_box_sdf(vec2 p, vec2 half_size, float radius) {
	vec2 q = abs(p) - half_size + vec2(radius);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void fragment() {
	vec2 center = rect_size * 0.5;

	// 内圈 = 卡片本身（= 本节点缩小 glow_size）。它会被卡片盖住，
	// 所以这里主要是算外圈那一段。
	vec2 inner_half = max(center - vec2(glow_size), vec2(1.0));

	float d = rounded_box_sdf(local_pos - center, inner_half, corner_radius);

	// 卡片内部不画（d < 0），从卡片边缘向外 glow_size 像素渐渐淡出
	float fade = clamp(1.0 - d / max(glow_size, 0.001), 0.0, 1.0);
	fade = fade * fade;

	COLOR = vec4(glow_color.rgb, glow_color.a * fade);
}
