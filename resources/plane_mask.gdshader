shader_type canvas_item;

// 遮罩纹理（ForwardShape 用的 plane_forward.svg）。
// 本节点（ColorRect）只在自己的 alpha 与遮罩 alpha 都 > 0 的地方绘制，
// 效果 = 用遮罩形状把颜色裁出来。
//
// repeat_disable 很重要：遮罩比节点小时，UV 超出 0..1 的区域必须视为透明，
// 否则默认的 repeat 会把图案平铺出去。
uniform sampler2D mask_texture : filter_linear, repeat_disable;

void fragment() {
	COLOR.a *= texture(mask_texture, UV).a;
}

