shader_type canvas_item;

// ============================================================
// ui_blur_mask.gdshader —— 选项面板唤出时，背后那层「半透明 + 模糊」遮罩
//
// 原理：采样**当前屏幕**（由场景里的 BackBufferCopy 先把已画好的内容
//       拷进 back buffer），做一圈多方向模糊，再和遮罩色按 mask_opacity 混合。
//       因为采样的是屏幕，所以背后的视频流 / 当前模式画面会被真正模糊掉，
//       而不是简单盖一块半透明色。
//
// ⚠️ 参数一律由 GDScript 设置（setting.gd::_apply_mask_params），
//    **不要**在 .tscn 里写 shader_parameter/xxx —— 那会覆盖本文件的默认值，
//    以后改这里就不生效了（这个坑本项目踩过）。
//
// ⚠️ 模糊半径很大时（>24px）会看出采样不足的条纹感，这时把 ring_taps 调到 3~4。
// ============================================================

// 屏幕纹理：就是遮罩背后已经画好的画面
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

// ---- 手机端可调参数 ----

// 模糊半径，单位是屏幕像素。0 = 完全不模糊（只剩半透明遮罩）。
uniform float blur_radius : hint_range(0.0, 32.0) = 10.0;

// 遮罩不透明度：0 = 完全透出背后画面，1 = 被遮罩色完全盖住。
uniform float mask_opacity : hint_range(0.0, 1.0) = 0.45;

// 遮罩颜色。默认近黑，略微偏蓝，看起来比纯黑通透一点。
uniform vec4 mask_color : source_color = vec4(0.03, 0.03, 0.05, 1.0);

// 模糊采样圈数（1~4）。总采样数 = 1 + 8 * ring_taps。
// 手机建议 2（17 次采样）；半径开很大时再调到 3。
uniform int ring_taps : hint_range(1, 4) = 2;


void fragment() {
	vec2 texel = 1.0 / vec2(textureSize(screen_texture, 0));
	vec2 uv = SCREEN_UV;

	// 中心点先算进去，权重为 1
	vec3 accum = texture(screen_texture, uv).rgb;
	float weight_sum = 1.0;

	// 8 个方向（4 正 + 4 斜）× ring_taps 圈
	for (int ring = 1; ring <= ring_taps; ring++) {
		float t = float(ring) / float(ring_taps);

		// 平方分布：越靠近中心采样越密，比等距采样更接近高斯核
		float radius = blur_radius * t * t;

		// 权重随距离线性衰减
		float w = 1.0 - t;
		vec2 d = vec2(radius) * texel;
		vec2 diag = d * 0.70710678; // 斜方向乘 1/sqrt(2)，保证到中心距离一致

		accum += texture(screen_texture, uv + vec2(d.x, 0.0)).rgb * w;
		accum += texture(screen_texture, uv - vec2(d.x, 0.0)).rgb * w;
		accum += texture(screen_texture, uv + vec2(0.0, d.y)).rgb * w;
		accum += texture(screen_texture, uv - vec2(0.0, d.y)).rgb * w;

		accum += texture(screen_texture, uv + diag).rgb * w;
		accum += texture(screen_texture, uv - diag).rgb * w;
		accum += texture(screen_texture, uv + vec2(diag.x, -diag.y)).rgb * w;
		accum += texture(screen_texture, uv + vec2(-diag.x, diag.y)).rgb * w;

		weight_sum += 8.0 * w;
	}

	vec3 blurred = accum / weight_sum;

	// 模糊结果 → 按 mask_opacity 混向遮罩色
	COLOR.rgb = mix(blurred, mask_color.rgb, mask_opacity);

	// ⚠️ 这里**必须保留进入 fragment 时的 alpha**：
	//    它是节点自己的 modulate.a（ColorRect 的 color 保持白色，所以
	//    COLOR.a 就等于 modulate.a）。setting.gd 正是靠 tween modulate:a
	//    做淡入淡出的；如果这里写死 1.0，遮罩就会瞬间出现/消失。
	COLOR.a = COLOR.a;
}
