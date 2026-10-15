extends Control

# ============================================================
# 设置页：移动倍数（SpinBox）+ 三根推流参数滑条
#
# ⚠️ 所有外观（ItemBg / 数值框 / 字号 / 圆角 / 间距 / 滑条颜色）
#    统一在 scripts/settings_style.gd 里 —— **改外观请改那里**。
#    本文件只描述「有哪些行、每行的取值范围」，以及改动后的保存 / 下发。
# ============================================================

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


func _ready() -> void:
	# 先套用统一样式，再填数据
	SettingsStyle.apply_list_styles(settings_list)
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
# 用滑条输入的设置行（推流帧率 / 推流画质 / 平滑程度）
# ============================================================


## 按 SLIDER_ROWS 表把每一行配置好：滑条范围、初始值、数值显示，
## 以及拖动时「存进 Options + 发给 Blender」。
##
## 行的结构约定（与 MoveSpeedRow 一致，只是把 SpinBox 换成 HSlider）：
##     XxxRow / ItemBg / RowContent / (XxxLabel + ValueBox/(XxxSlider + ValueText))
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

		SettingsStyle.style_slider(slider, SettingsStyle.row_height(row))

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
			SettingsStyle.VALUE_TEXT_NAME, true, false
		) as Label

		SettingsStyle.update_value_text(
			value_text, slider.value, spec["decimals"]
		)

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


## 拖动滑条时：更新数字显示 → 存进 Options → 告诉 Blender。
func _on_slider_changed(
	value: float,
	spec: Dictionary,
	value_text: Label
) -> void:
	SettingsStyle.update_value_text(value_text, value, spec["decimals"])

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

		SettingsStyle.update_value_text(
			binding["text"], clamped, spec["decimals"]
		)
