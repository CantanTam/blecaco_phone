class_name SettingsStyle

# ============================================================
# 设置列表的统一外观 —— 唯一入口
#
# addon_set / camera_select 等设置页的外观只在这里定义，
# 由 apply_list_styles() 按「节点名 / 节点类型」统一套用。
# 以后加新页面、新行，只要结构一致就自动套用同一套样式。
#
# 结构约定：
#     XxxRow (HBoxContainer)
#       └ ItemBg (PanelContainer)
#           └ RowContent (HBoxContainer)
#               ├ XxxLabel (Label) 或 XxxIcon (TextureRect)
#               └ ValueBox (Panel)              ← 兼作遮罩（clip_children = 2）
#                   ├ XxxSlider (HSlider) 或 SpinBox
#                   └ ValueText (Label)
# ============================================================

## ItemBg 的底色（RGB + 透明度）。默认：白色 50% 半透明。
const ITEM_BG_COLOR := Color(1.0, 1.0, 1.0, 0.5)

## ItemBg 的圆角大小（px）
const ITEM_BG_RADIUS := 30

## Label 文本 与 数值 共用的字号
const FONT_SIZE := 50

## 数值框的底色
const VALUE_BG_COLOR := Color(0.1, 0.1, 0.1, 0.6)

## 数值框的圆角大小（px）
const VALUE_BG_RADIUS := 30

## 数值框与 ItemBg 之间的内边距（px）
const VALUE_PADDING := 10

## 行与行之间的间距（px）
const ITEM_PADDING := 20

## 滑条的颜色（RGB + 透明度）。默认 #00ff00ff = 不透明纯绿。
## ⚠️ 这是「滑条本体」（已选中的前半段）的颜色；未选中那段不画东西，
##    底色由 ValueBox 那个框负责。
## （常量名按你给的 SilderColor 保留原拼写）
const SILDER_COLOR := Color(0.0, 1.0, 0.0, 1.0)

## 行背景的节点名。设置列表下凡是叫这个名字的 PanelContainer 都会被套样式。
const ITEM_BG_NAME := "ItemBg"

## 数值显示 Label 的节点名（挂在滑条节点里面，居中盖在滑条上）
const VALUE_TEXT_NAME := "ValueText"

## 数值框的节点名。这个 Panel 还负责用 clip_children 裁切里面的滑条 ——
## 滑条的圆角形状就是靠它裁出来的。
const VALUE_BOX_NAME := "ValueBox"

## 1×1 全透明贴图（盖掉滑条默认的小圆点），只创建一次所有滑条共用
static var _blank_texture_cache: ImageTexture


# ============================================================
# 套用
# ============================================================


## 把整个设置列表套上统一样式：行间距 + 所有 ItemBg / Label / SpinBox / ValueBox。
##
## 用「遍历 + 判名字/判类型」而不是写死路径，以后加新行不用回来改这里。
## ⚠️ 滑条（HSlider）不在这里处理：它的轨道厚度要按行高算，
##    所以由各自页面调用 style_slider()，见那边的说明。
static func apply_list_styles(list: VBoxContainer) -> void:
	list.add_theme_constant_override("separation", ITEM_PADDING)

	for node in list.find_children("*", "", true, false):
		if node.name == ITEM_BG_NAME and node is PanelContainer:
			style_item_bg(node as PanelContainer)
		elif node.name == VALUE_BOX_NAME and node is Panel:
			style_value_box(node as Panel)
		elif node is Label:
			(node as Label).add_theme_font_size_override(
				"font_size", FONT_SIZE
			)
		elif node is SpinBox:
			style_spin_box(node as SpinBox)


## ItemBg（行背景）：底色、圆角，以及给子节点留的内边距。
##
## ⚠️ 内边距走 StyleBox 的 content_margin —— PanelContainer 就是用它来决定
##    子节点离边框多远的，所以 VALUE_PADDING 会同时作用在上下左右。
static func style_item_bg(item_bg: PanelContainer) -> void:
	var style := item_bg.get_theme_stylebox("panel") as StyleBoxFlat

	if style == null:
		push_warning("[SettingsStyle] %s 上没有 StyleBoxFlat" % item_bg.name)
		return

	style.bg_color = ITEM_BG_COLOR
	set_corner_radius(style, ITEM_BG_RADIUS)

	style.content_margin_left = VALUE_PADDING
	style.content_margin_top = VALUE_PADDING
	style.content_margin_right = VALUE_PADDING
	style.content_margin_bottom = VALUE_PADDING


## 数值框（滑条行）：底色 + 圆角。
##
## ⚠️ 这个 Panel 同时是「遮罩」：场景里它的 clip_children = 2
##    （CLIP_CHILDREN_AND_DRAW），所以里面的滑条会被它的圆角形状裁掉 ——
##    滑条本身画的是方角矩形，圆角完全来自这里。
static func style_value_box(value_box: Panel) -> void:
	var style := value_box.get_theme_stylebox("panel") as StyleBoxFlat

	if style == null:
		push_warning("[SettingsStyle] %s 上没有 StyleBoxFlat" % value_box.name)
		return

	style.bg_color = VALUE_BG_COLOR
	set_corner_radius(style, VALUE_BG_RADIUS)


## 数值输入框（SpinBox）：字号 + 底色 + 圆角。
##
## ⚠️ SpinBox 自己不画背景，它内部有一个 LineEdit（内部子节点），
##    外观来自 LineEdit/styles/*。所以底色和圆角必须写在那几份 stylebox 上；
##    写在 SpinBox 自己的 theme_override_styles 上是没用的。
##
##    字号则走 Theme 的 default_font_size，内部 LineEdit 会自动继承。
static func style_spin_box(spin_box: SpinBox) -> void:
	var value_theme := spin_box.theme

	if value_theme == null:
		# 没挂独立 Theme 的 SpinBox：至少把字号补上
		spin_box.get_line_edit().add_theme_font_size_override(
			"font_size", FONT_SIZE
		)
		return

	value_theme.default_font_size = FONT_SIZE

	for style_name in ["normal", "focus", "read_only"]:
		var style := value_theme.get_stylebox(style_name, "LineEdit")

		if not (style is StyleBoxFlat):
			continue

		var flat := style as StyleBoxFlat

		# focus 那份是 draw_center = false 的（只画一圈描边），不该改底色
		if flat.draw_center:
			flat.bg_color = VALUE_BG_COLOR

		set_corner_radius(flat, VALUE_BG_RADIUS)


## 滑条外观：颜色用 SILDER_COLOR，形状交给外面的 ValueBox 裁切。
##
## ⚠️ 这里**不设圆角**：滑条画的是方角矩形，圆角由 ValueBox 的
##    clip_children 裁出来（见 style_value_box 的说明）。
##    未选中那段轨道不画东西，底色是 ValueBox 那个框画的。
##
## ⚠️ 填充段的高度由 StyleBoxFlat 的最小高度决定
##    （最小高度 = content_margin_top + content_margin_bottom），
##    所以要让它撑满整个数值框，就得把「一半的高度」写进上下 content_margin。
static func style_slider(slider: HSlider, row_height_value: float) -> void:
	var box_height := maxf(row_height_value - VALUE_PADDING * 2.0, 1.0)
	var half := box_height * 0.5

	for style_name in ["slider", "grabber_area", "grabber_area_highlight"]:
		var style := slider.get_theme_stylebox(style_name)

		if not (style is StyleBoxFlat):
			continue

		var flat := style as StyleBoxFlat

		flat.content_margin_top = half
		flat.content_margin_bottom = half
		set_corner_radius(flat, 0)

		if style_name == "slider":
			# 轨道：什么都不画，底色交给 ValueBox
			flat.draw_center = false
			flat.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		else:
			# 已选中的前半段 = 滑条本体
			flat.draw_center = true
			flat.bg_color = SILDER_COLOR

	remove_grabber(slider)


## 去掉滑条上的小圆点（grabber）。
##
## Godot 没有「隐藏 grabber」的开关，只能用一张 1×1 全透明的贴图去盖掉
## 默认的那几个图标。顺带好处：轨道两端不再为圆点留出空隙。
static func remove_grabber(slider: HSlider) -> void:
	for icon_name in ["grabber", "grabber_highlight", "grabber_disabled"]:
		slider.add_theme_icon_override(icon_name, blank_texture())


static func blank_texture() -> ImageTexture:
	if _blank_texture_cache == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
		_blank_texture_cache = ImageTexture.create_from_image(image)

	return _blank_texture_cache


static func set_corner_radius(style: StyleBoxFlat, radius: int) -> void:
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_right = radius
	style.corner_radius_bottom_left = radius


## 行高。约定：行容器（StreamFpsRow / MoveSpeedRow / CameraItem …）的
## custom_minimum_size.y 就是行高。
static func row_height(row: Control) -> float:
	if row.custom_minimum_size.y > 0.0:
		return row.custom_minimum_size.y

	# 没设最小值时的兜底
	return 180.0


## 数值显示：整数不补零，小数固定位数（0 → "0.00"）。
##
## ⚠️ 用 "%.2f" 这种固定小数位，别用 String.num()：
##    后者不会补零（0 会显示成 "0.0" 而不是 "0.00"）。
static func update_value_text(label: Label, value: float, decimals: int) -> void:
	if label == null:
		return

	if decimals <= 0:
		label.text = str(int(round(value)))
		return

	label.text = ("%." + str(decimals) + "f") % value
