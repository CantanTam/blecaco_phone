extends Control

# ============================================================
# SettingsList 统一样式变量
#
# 整个设置列表的外观只在这里定义，由 _apply_settings_list_style() 统一套用。
# 以后往 SettingsList 里加新行，只要结构一致：
#     XxxRow (HBoxContainer)
#       └ ItemBg (PanelContainer)
#           └ RowContent (HBoxContainer)
#               ├ XxxLabel (Label)
#               └ XxxInput (SpinBox)
# 就会自动套用同一套样式，不需要改下面的代码。
# ============================================================

## ItemBg 的底色（RGB + 透明度）。默认：白色 50% 半透明。
const ITEM_BG_COLOR := Color(1.0, 1.0, 1.0, 0.5)

## ItemBg 的圆角大小（px）
const ITEM_BG_RADIUS := 30

## Label 文本 与 SpinBox 数值 共用的字号
const FONT_SIZE := 50

## 数值输入框（SpinBox）的底色
const VALUE_BG_COLOR := Color(0.1, 0.1, 0.1, 0.6)

## 数值输入框（SpinBox）的圆角大小（px）
const VALUE_BG_RADIUS := 30

## 数值输入框与 ItemBg 之间的内边距（px）
const VALUE_PADDING := 10

## 行背景的节点名。SettingsList 下凡是叫这个名字的 PanelContainer
## 都会按上面的变量套样式。
const ITEM_BG_NAME := "ItemBg"


@onready var settings_list: VBoxContainer = $SetScrollPage/SettingsList
@onready var move_speed_spin_box: SpinBox = (
	$SetScrollPage/SettingsList/MoveSpeedRow/ItemBg/RowContent/SpeedInput
)


func _ready() -> void:
	# 先套用统一样式，再填数据
	_apply_settings_list_style()

	# 设置允许的数值范围
	move_speed_spin_box.min_value = 0.01
	move_speed_spin_box.max_value = 100.0
	move_speed_spin_box.step = 0.01

	# 读取已保存的移动倍数
	move_speed_spin_box.value = clampf(
		Options.get_float("move_speed"),
		0.01,
		100.0
	)

	# 数值改变时，自动保存
	move_speed_spin_box.value_changed.connect(
		_on_move_speed_changed
	)


func _on_move_speed_changed(value: float) -> void:
	Options.set_value("move_speed", value)


# ============================================================
# 统一样式的套用
# ============================================================


## 把上面那些样式变量应用到 SettingsList 下的所有行。
##
## 用「遍历 + 判名字/判类型」而不是写死路径，以后加新行不用回来改这里。
func _apply_settings_list_style() -> void:
	for node in settings_list.find_children("*", "", true, false):
		if node.name == ITEM_BG_NAME and node is PanelContainer:
			_style_item_bg(node as PanelContainer)
		elif node is Label:
			(node as Label).add_theme_font_size_override(
				"font_size", FONT_SIZE
			)
		elif node is SpinBox:
			_style_spin_box(node as SpinBox)


## ItemBg（行背景）：底色、圆角，以及给子节点留的内边距。
##
## ⚠️ 内边距走 StyleBox 的 content_margin —— PanelContainer 就是用它来决定
##    子节点离边框多远的，所以 VALUE_PADDING 会同时作用在数值框的上下左右。
func _style_item_bg(item_bg: PanelContainer) -> void:
	var style := item_bg.get_theme_stylebox("panel") as StyleBoxFlat

	if style == null:
		push_warning(
			"[AddonSet] %s 上没找到 StyleBoxFlat，跳过" % item_bg.name
		)
		return

	style.bg_color = ITEM_BG_COLOR
	_set_corner_radius(style, ITEM_BG_RADIUS)

	style.content_margin_left = VALUE_PADDING
	style.content_margin_top = VALUE_PADDING
	style.content_margin_right = VALUE_PADDING
	style.content_margin_bottom = VALUE_PADDING


## 数值输入框：字号 + 底色 + 圆角。
##
## ⚠️ SpinBox 自己不画背景，它内部有一个 LineEdit（内部子节点），
##    外观来自 LineEdit/styles/*。所以底色和圆角必须写在那几份 stylebox 上；
##    写在 SpinBox 自己的 theme_override_styles 上是没用的。
##
##    字号则走 Theme 的 default_font_size，内部 LineEdit 会自动继承。
func _style_spin_box(spin_box: SpinBox) -> void:
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

		_set_corner_radius(flat, VALUE_BG_RADIUS)


func _set_corner_radius(style: StyleBoxFlat, radius: int) -> void:
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_right = radius
	style.corner_radius_bottom_left = radius
