class_name ModeCoverStyle

# ============================================================
# ModeSelect 卡片外观 —— 统一入口（要调就改这里）
#
#   ① 圆角：卡片是圆角白卡；节点上开了 clip_children 用它当遮罩，
#          把封面图裁成四角圆角 —— **所有卡片都有**。
#   ② 光晕：**只有选中 / 中间高亮放大那张有**，画在
#          resources/cover_glow.gdshader 里，沿着卡片的圆角规形向外渐隐。
#
# ⚠️ 光晕不能用 StyleBoxFlat 的 shadow 做：Godot 的阴影是**方角**的，
#    不跟 corner_radius 走，四角会留下直角残留（实测确认）。
# ============================================================

## 四个圆角半径（px）
## ⚠️ 卡片的样式盒和光晕 shader 共用这个值，改这里两边一起变。
const CORNER_RADIUS := 40

## 卡片底色。白色 —— 和封面图自己的白底一致；必须不透明。
const COVER_BG := Color(1.0, 1.0, 1.0, 1.0)

# ------------------------------------------------------------------
# 光晕（只有选中那张有）—— 这几个就是你要手调的
# ------------------------------------------------------------------

## 光晕向外扩散的厚度（px）。调大 = 范围更大。
const GLOW_SIZE := 28.0

## 光晕颜色 + 强度。alpha 就是强度，比如 0.4 = 更淡、1.0 = 最亮。
const GLOW_COLOR := Color(0.0, 1.0, 0.0, 0.7)


## 卡片样式盒：圆角白卡（不带光晕）。
## 圆角同时也是 clip_children 的遮罩形状 —— 封面图的四角就是被它切掉的。
static func make_cover() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()

	style.bg_color = COVER_BG
	style.corner_radius_top_left = CORNER_RADIUS
	style.corner_radius_top_right = CORNER_RADIUS
	style.corner_radius_bottom_right = CORNER_RADIUS
	style.corner_radius_bottom_left = CORNER_RADIUS
	style.corner_detail = 20

	return style


## 把光晕参数写进光晕节点的材质（resources/cover_glow.gdshader）。
static func apply_glow(material: ShaderMaterial) -> void:
	if material == null:
		return

	material.set_shader_parameter("glow_color", GLOW_COLOR)
	material.set_shader_parameter("glow_size", GLOW_SIZE)
	material.set_shader_parameter("corner_radius", CORNER_RADIUS)
