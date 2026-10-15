class_name ModeCoverStyle

# ============================================================
# ModeSelect 卡片的统一外观 —— 唯一入口
#
# 卡片是 Panel + 里面的 CoverImage。这里的样式盒同时负责三件事：
#   1) 圆角：节点上开了 clip_children，用这个圆角形状把图片裁成四角圆角
#   2) 挡住阴影向内的部分：Godot 的阴影画在背景**后面**，背景不透明时
#      就只剩外面一圈光晕；半透明的话绿色会透进卡片里
#   3) 光晕：shadow 就是「居中放大的同一形状」，所以它天然沿着圆角规形走，
#      也会跟着卡片的放大 / 移动动画一起动
#
# ⚠️ 光晕**只给选中（中间高亮放大）的那张**：make(true) 给选中，其余用 make(false)。
# ============================================================

## 四个圆角半径（px）
const CORNER_RADIUS := 40

## 卡片底色。白色 —— 和封面图自己的白底一致；
## ⚠️ 必须不透明，否则光晕会从卡片内部透出来。
const COVER_BG := Color(1.0, 1.0, 1.0, 1.0)

## 光晕向外扩散的厚度（px）
const GLOW_SIZE := 28

## 光晕颜色 + 亮度（alpha 就是亮度）
const GLOW_COLOR := Color(0.0, 1.0, 0.0, 0.7)


## 造一份卡片样式盒。
##
##   with_glow = true  → 带光晕（选中 / 中间高亮的那张）
##   with_glow = false → 不带光晕（其它卡片）
static func make(with_glow: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()

	style.bg_color = COVER_BG
	style.corner_radius_top_left = CORNER_RADIUS
	style.corner_radius_top_right = CORNER_RADIUS
	style.corner_radius_bottom_right = CORNER_RADIUS
	style.corner_radius_bottom_left = CORNER_RADIUS
	style.corner_detail = 20

	if with_glow:
		style.shadow_color = GLOW_COLOR
		style.shadow_size = GLOW_SIZE
		# 偏移 0 = 居中放大
		style.shadow_offset = Vector2.ZERO

	return style
