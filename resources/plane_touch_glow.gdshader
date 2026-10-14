shader_type canvas_item;

// ============================================================
// 指尖光晕圆（挂在 ForwardColor 上）
// ============================================================
// 中心实心、向外渐变到完全透明的圆。
// 圆心由 plane_forward_area.gd 写入：x 固定为区域水平中心，y 跟随手指。
// ============================================================

// ------- 下面 3 个就是全部可调变量（也可在检查器里改）-------

// 圆形的颜色（RGB；A 通道为整体强度）
uniform vec4 circle_color : source_color = vec4(1.0, 0.0, 0.0, 1.0);

// 圆的直径（像素）
uniform float circle_size : hint_range(1.0, 2048.0) = 600.0;

// 渐变起点比例（圆心往外多少才开始渐变）：
//   0.0 = 从圆心就开始渐变（圆心实心，一路淡到圆周）
//   1.0 = 到圆周才开始渐变（内部全实心，边缘直接切断）
uniform float gradient_start : hint_range(0.0, 1.0) = 0.0;

// ------- 下面 1 个是形状遮罩 -------

// 用 ForwardShape 那张 plane_forward.svg 做裁剪：
// 圆只画在遮罩不透明的区域内，于是得到一个「被箭头裁出来的渐变圆」，
// 再叠在 ForwardBottomColor 上面。
uniform sampler2D mask_texture : filter_linear, repeat_disable;

// ------- 下面 2 个由脚本自动写入，不用手动改 -------

// 本节点的像素尺寸：把 UV 换算成像素，保证圆不会被拉成椭圆
uniform vec2 node_size = vec2(1.0);

// 圆心位置（本节点的局部像素坐标）
uniform vec2 circle_center = vec2(0.0);

void fragment() {
	vec2 pixel = UV * node_size;
	float radius = max(circle_size * 0.5, 0.001);
	float distance_ratio = distance(pixel, circle_center) / radius;

	// 夹到 0.999：GLSL 规定 smoothstep 的 edge0 >= edge1 时结果未定义
	float fade_begin = min(gradient_start, 0.999);

	// 圆周以内按距离渐隐，圆周以外为 0
	float fade = 1.0 - smoothstep(fade_begin, 1.0, distance_ratio);

	// 形状遮罩：把渐变圆裁剪成箭头形状
	float shape = texture(mask_texture, UV).a;

	// COLOR.a 里带着 ColorRect 自身的颜色与 modulate，
	// 乘上它们之后仍然可以用 modulate 做整体淡入淡出。
	COLOR = vec4(circle_color.rgb, circle_color.a * fade * shape * COLOR.a);
}


