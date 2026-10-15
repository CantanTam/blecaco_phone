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

## 行与行之间的间距（px）
const ITEM_PADDING := 20

## 滑条的颜色（RGB + 透明度）。默认 #00ff00ff = 不透明纯绿。
##
## ⚠️ 这是「滑条本体」（已选中的前半段）的颜色。后面那段轨道不画东西，
##    底色由 ValueBox 那个框负责。
## （常量名按你给的 SilderColor 保留原拼写）
const SILDER_COLOR := Color(0.0, 1.0, 0.0, 1.0)

## 行背景的节点名。SettingsList 下凡是叫这个名字的 PanelContainer
## 都会按上面的变量套样式。
const ITEM_BG_NAME := "ItemBg"

## 数值显示 Label 的节点名（挂在滑条节点里面，居中盖在滑条上）
const VALUE_TEXT_NAME := "ValueText"

## 数值框的节点名（滑条行的深色圆角框）。
## ⚠️ 这个 Panel 还负责用 clip_children 裁切里面的滑条 ——
##    滑条的圆角形状就是靠它裁出来的，所以它的圆角必须和 VALUE_BG_RADIUS 一致。
const VALUE_BOX_NAME := "ValueBox"

# ============================================================
# 用滑条输入的设置行
#
# 每条描述一行：Options 用的键、发给 Blender 的 setting 名、取值范围。
# key 与 setting 一一对应，setting 就是 blecaco/addon_property.py 里的属性名：
#     fps     → props.fps      推流帧率
#     quality → props.quality  推流画质
#     smooth  → props.smooth   平滑程度
#
# ⚠️ min/max/step 必须与 addon_property.py 里声明的范围保持一致。
# 加新行：这里补一条 + 场景里照 StreamFpsRow 的结构摆好节点即可。
# ============================================================
const SLIDER_ROWS := [
	{
		"row": "StreamFpsRow",
		"key": "blender/fps",
		"setting": "fps",
		"min": 1.0,
		"max": 30.0,
		"step": 1.0,
		"decimals": 0,
	},
	{
		"row": "StreamQualityRow",
		"key": "blender/quality",
		"setting": "quality",
		"min": 10.0,
		"max": 100.0,
		"step": 1.0,
		"decimals": 0,
	},
	{
		"row": "StreamSmoothRow",
		"key": "blender/smooth",
		"setting": "smooth",
		"min": 0.0,
		"max": 1.0,
		"step": 0.01,
		"decimals": 2,
	},
]


@onready var settings_list: VBoxContainer = $SetScrollPage/SettingsList
# 路径：AddonSet → ContentHost → Setting → ModeContainer → Main → Connection
@onready var connection: Node = get_node_or_null("../../../../Connection")
@onready var move_speed_spin_box: SpinBox = (
	$SetScrollPage/SettingsList/MoveSpeedRow/ItemBg/RowContent/SpeedInput
)

## 每行滑条的绑定（spec + 滑条 + 数字 Label），用于接收 Blender 推来的校准值
var _slider_bindings: Array = []

## 1×1 全透明贴图（用来盖掉滑条默认的小圆点），只创建一次、所有滑条共用
var _blank_texture_cache: ImageTexture


func _ready() -> void:
	# 先套用统一样式，再填数据
	_apply_settings_list_style()
	_setup_slider_rows()

	# Blender 连上后会把它的推流参数推过来做校准（见 main.gd），
	# 所以 Options 一变就把对应滑条跟着挪过去
	Options.changed.connect(_on_options_changed)

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
##
## ⚠️ 滑条（HSlider）不在这里处理：它的轨道厚度要按行高算，
##    所以放在 _setup_slider_rows() → _style_slider()，见那边的说明。
func _apply_settings_list_style() -> void:
	# 行与行之间的间距
	settings_list.add_theme_constant_override("separation", ITEM_PADDING)

	for node in settings_list.find_children("*", "", true, false):
		if node.name == ITEM_BG_NAME and node is PanelContainer:
			_style_item_bg(node as PanelContainer)
		elif node.name == VALUE_BOX_NAME and node is Panel:
			_style_value_box(node as Panel)
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


## 数值框（滑条行）：底色 + 圆角。
##
## ⚠️ 这个 Panel 同时是「遮罩」：场景里它的 clip_children = 2
##    （CLIP_CHILDREN_AND_DRAW），所以里面的滑条会被它的圆角形状裁掉 ——
##    滑条本身画的是方角矩形，圆角完全来自这里。
func _style_value_box(value_box: Panel) -> void:
	var style := value_box.get_theme_stylebox("panel") as StyleBoxFlat

	if style == null:
		push_warning(
			"[AddonSet] %s 上没找到 StyleBoxFlat，跳过" % value_box.name
		)
		return

	style.bg_color = VALUE_BG_COLOR
	_set_corner_radius(style, VALUE_BG_RADIUS)


# ============================================================
# 用滑条输入的设置行（推流帧率 / 推流画质 / 平滑程度）
# ============================================================


## 按 SLIDER_ROWS 表把每一行配置好：滑条范围、初始值、数值显示，
## 以及拖动时「存进 Options + 发给 Blender」。
##
## 行的结构约定（与 MoveSpeedRow 一致，只是把 SpinBox 换成 HSlider）：
##     XxxRow / ItemBg / RowContent / (XxxLabel + XxxSlider / ValueText)
func _setup_slider_rows() -> void:
	for spec in SLIDER_ROWS:
		var row := settings_list.get_node_or_null(spec["row"]) as Control

		if row == null:
			push_warning("[AddonSet] SettingsList 里找不到 %s" % spec["row"])
			continue

		var sliders := row.find_children("*", "HSlider", true, false)

		if sliders.is_empty():
			push_warning("[AddonSet] %s 里没有 HSlider" % spec["row"])
			continue

		var slider := sliders[0] as HSlider

		_style_slider(slider, _row_height(row))

		# 范围与初始值：初始值取 Options（没有存档时就是 DEFAULTS 里的值）
		slider.min_value = spec["min"]
		slider.max_value = spec["max"]
		slider.step = spec["step"]
		slider.value = clampf(
			Options.get_float(spec["key"]),
			spec["min"],
			spec["max"]
		)

		var value_text := slider.find_child(
			VALUE_TEXT_NAME, true, false
		) as Label

		_update_value_text(value_text, slider.value, spec["decimals"])

		slider.value_changed.connect(
			_on_slider_changed.bind(spec, value_text)
		)

		# 记下来，Blender 推来新值时好把滑条跟着挪过去
		# （见 _on_options_changed）
		_slider_bindings.append({
			"spec": spec,
			"slider": slider,
			"text": value_text,
		})


## 滑条外观：颜色用 SILDER_COLOR，形状交给外面的 ValueBox 裁切。
##
## ⚠️ 这里**不设圆角**：滑条画的是方角矩形，圆角由 ValueBox 的
##    clip_children 裁出来（见 _style_value_box 的说明）。
##    未选中那段轨道不画东西，底色是 ValueBox 那个框画的。
##
## ⚠️ 填充段的高度由 StyleBoxFlat 的最小高度决定
##    （最小高度 = content_margin_top + content_margin_bottom），
##    所以要让它撑满整个数值框，就得把「一半的高度」写进上下 content_margin。
func _style_slider(slider: HSlider, row_height: float) -> void:
	var box_height := maxf(row_height - VALUE_PADDING * 2.0, 1.0)
	var half := box_height * 0.5

	for style_name in ["slider", "grabber_area", "grabber_area_highlight"]:
		var style := slider.get_theme_stylebox(style_name)

		if not (style is StyleBoxFlat):
			continue

		var flat := style as StyleBoxFlat

		flat.content_margin_top = half
		flat.content_margin_bottom = half
		_set_corner_radius(flat, 0)

		if style_name == "slider":
			# 轨道：什么都不画，底色交给 ValueBox
			flat.draw_center = false
			flat.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		else:
			# 已选中的前半段 = 滑条本体
			flat.draw_center = true
			flat.bg_color = SILDER_COLOR

	_remove_grabber(slider)


## 去掉滑条上的小圆点（grabber）。
##
## Godot 没有「隐藏 grabber」的开关，只能用一张 1×1 全透明的贴图去盖掉
## 默认的那几个图标。顺带好处：轨道两端不再为圆点留出空隙。
func _remove_grabber(slider: HSlider) -> void:
	for icon_name in ["grabber", "grabber_highlight", "grabber_disabled"]:
		slider.add_theme_icon_override(icon_name, _blank_texture())


func _blank_texture() -> ImageTexture:
	if _blank_texture_cache == null:
		var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
		_blank_texture_cache = ImageTexture.create_from_image(image)

	return _blank_texture_cache


## 行高。约定：行容器（StreamFpsRow / MoveSpeedRow …）的
## custom_minimum_size.y 就是行高。
func _row_height(row: Control) -> float:
	if row.custom_minimum_size.y > 0.0:
		return row.custom_minimum_size.y

	# 没设最小值时的兜底
	return 180.0


## 拖动滑条时：更新数字显示 → 存进 Options → 告诉 Blender。
func _on_slider_changed(
	value: float,
	spec: Dictionary,
	value_text: Label
) -> void:
	_update_value_text(value_text, value, spec["decimals"])

	# 本机保存，下次打开还是这个值
	Options.set_value(spec["key"], value)

	# ⚠️ fps / quality 在 Blender 那边是 IntProperty，必须发整数，
	#    发浮点会被拒绝赋值。
	var payload: Variant = value

	if spec["decimals"] == 0:
		payload = int(round(value))

	if connection == null:
		push_warning(
			"[AddonSet] 找不到 Connection，%s 没能发给 Blender"
			% spec["setting"]
		)
		return

	# setting 名 = blecaco/addon_property.py 里的属性名
	connection.call("send_setting", spec["setting"], payload)


func _update_value_text(label: Label, value: float, decimals: int) -> void:
	if label == null:
		return

	if decimals <= 0:
		label.text = str(int(round(value)))
		return

	# ⚠️ 用 "%.2f" 这种固定小数位，别用 String.num()：
	#    后者不会补零（0 会显示成 "0.0" 而不是 "0.00"）。
	label.text = ("%." + str(decimals) + "f") % value


## Options 里任意选项变化时调用。
##
## 主要用途：Blender 连上后会把它的推流参数推过来做「校准」（见 main.gd），
## 这里负责把滑条挪到那个值上。
func _on_options_changed(a_key: String, a_value: Variant) -> void:
	for binding in _slider_bindings:
		var spec: Dictionary = binding["spec"]

		if spec["key"] != a_key:
			continue

		if not (a_value is float or a_value is int):
			return

		var clamped := clampf(float(a_value), spec["min"], spec["max"])

		# ⚠️ 必须用 set_value_no_signal()：否则会被当成用户拖动，
		#    又原样发回 Blender，两边来回弹。
		var slider: HSlider = binding["slider"]
		slider.set_value_no_signal(clamped)

		_update_value_text(binding["text"], clamped, spec["decimals"])
