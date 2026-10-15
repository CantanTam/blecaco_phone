extends Control

# ============================================================
# 摄像机选择页
#
# 数据来自 Blender：main.gd 收到 setting/cameras 后写进 Options，结构是
#     {"active": "活动摄像机名", "names": ["CamA", "CamB", ...]}
#
# 每一行（结构对齐 addon_set 的行，外观见 scripts/settings_style.gd）：
#     左 —— 图标：活动 = ActiveCamera.svg，非活动 = InactiveCamera.svg
#     右 —— 数值框里：摄像机名字 + 一条滑条（活动 = 100%，非活动 = 0%）
#
# 点任意一行 → 请求 Blender 把那台摄像机设为活动摄像机。
# Blender 处理后会把新的摄像机状态推回来（见 blecaco/setting.py），
# 所以这里不做乐观更新，一切以 Blender 为准。
# ============================================================

## 图标（活动 / 非活动）
const ICON_ACTIVE := preload("res://resources/ActiveCamera.svg")
const ICON_INACTIVE := preload("res://resources/InactiveCamera.svg")

## Options 里存摄像机状态的键（由 main.gd 写入）
const CAMERAS_KEY := "blender/cameras"

## 发给 Blender 的 setting 名
const ACTIVE_CAMERA_SETTING := "active_camera"

## 模板行的节点名（场景里放着，用来复制出每一台摄像机）
const TEMPLATE_NAME := "CameraItem"

## 图标节点名
const ICON_NAME := "CameraIcon"


@onready var camera_list: VBoxContainer = $SetScrollPage/CameraList
# 路径：CameraSelect → ContentHost → Setting → ModeContainer → Main → Connection
@onready var connection: Node = get_node_or_null("../../../../Connection")

## 上一次用过的摄像机状态（字符串化）。一样就不重建，避免列表闪烁。
var _last_signature := ""


func _ready() -> void:
	SettingsStyle.apply_list_styles(camera_list)

	# 模板行自己不出现在列表里
	var template := camera_list.get_node_or_null(TEMPLATE_NAME) as Control

	if template != null:
		template.visible = false

	# Blender 增删摄像机 / 改名 / 换活动摄像机时会把新状态推过来 → 重建列表
	Options.changed.connect(_on_options_changed)

	_rebuild()


# ============================================================
# 列表构建
# ============================================================


## 按 Options 里的摄像机状态重建整个列表。
##
## ⚠️ 状态没变就直接返回：Blender 那边可能重复推送，重建会让列表闪一下。
func _rebuild() -> void:
	var state := _camera_state()
	var signature := str(state)

	if signature == _last_signature:
		return

	_last_signature = signature

	var template := camera_list.get_node_or_null(TEMPLATE_NAME) as Control

	# 先把旧行清掉（模板留着）。
	# ⚠️ 用 remove_child + queue_free：只 queue_free 的话旧行会留到帧尾，
	#    和新行重叠显示一帧。
	for child in camera_list.get_children():
		if child == template:
			continue

		camera_list.remove_child(child)
		child.queue_free()

	var names: Array = state.get("names", [])

	if names.is_empty():
		_add_empty_hint()
		return

	var active := str(state.get("active", ""))

	for camera_name in names:
		_add_row(template, str(camera_name), str(camera_name) == active)


## 一台摄像机一行。
func _add_row(template: Control, camera_name: String, is_active: bool) -> void:
	if template == null:
		push_error("[CameraSelect] 场景里找不到模板行 %s" % TEMPLATE_NAME)
		return

	var row := template.duplicate() as Control
	row.name = "CameraItem_" + camera_name
	row.visible = true
	camera_list.add_child(row)

	# 图标：活动 / 非活动
	var icon := row.find_child(ICON_NAME, true, false) as TextureRect

	if icon != null:
		icon.texture = ICON_ACTIVE if is_active else ICON_INACTIVE

	# 滑条：只当指示器用（活动 = 100%，非活动 = 0%），不接受拖动
	var sliders := row.find_children("*", "HSlider", true, false)

	if not sliders.is_empty():
		var slider := sliders[0] as HSlider

		SettingsStyle.style_slider(slider, SettingsStyle.row_height(row))
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 1.0
		slider.set_value_no_signal(1.0 if is_active else 0.0)
		slider.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 名字显示在数值框中央
	var value_text := row.find_child(
		SettingsStyle.VALUE_TEXT_NAME, true, false
	) as Label

	if value_text != null:
		value_text.text = camera_name

	# 整行可点：点一下就切到这台摄像机
	var item_bg := row.find_child(
		SettingsStyle.ITEM_BG_NAME, true, false
	) as Control

	if item_bg != null:
		item_bg.mouse_filter = Control.MOUSE_FILTER_STOP
		item_bg.gui_input.connect(_on_row_gui_input.bind(camera_name))


## 一台摄像机都没有时给个提示（不然页面看起来是坏的）。
func _add_empty_hint() -> void:
	var hint := Label.new()
	hint.text = "（没有摄像机）"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", SettingsStyle.FONT_SIZE)
	camera_list.add_child(hint)


# ============================================================
# 与 Blender 同步
# ============================================================


## 读 Blender 推来的摄像机状态（结构见文件开头）。
func _camera_state() -> Dictionary:
	var value: Variant = Options.get_value(CAMERAS_KEY, {})

	if value is Dictionary:
		return value

	return {}


func _on_options_changed(a_key: String, _a_value: Variant) -> void:
	if a_key != CAMERAS_KEY:
		return

	_rebuild()


## 点某一行的处理：请求 Blender 把它切成活动摄像机。
##
## 只认「按下」那一下（手机上是触摸按下，PC 上是鼠标左键），
## 松开 / 拖动不重复发。
func _on_row_gui_input(event: InputEvent, camera_name: String) -> void:
	var pressed := false

	if event is InputEventScreenTouch:
		pressed = event.pressed
	elif event is InputEventMouseButton:
		pressed = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	else:
		return

	if not pressed:
		return

	if connection == null:
		push_warning("[CameraSelect] 找不到 Connection，无法切换摄像机")
		return

	if not connection.call("send_setting", ACTIVE_CAMERA_SETTING, camera_name):
		push_warning("[CameraSelect] 切换摄像机请求发送失败")
		return

	print("[CameraSelect] 已请求切换活动摄像机：", camera_name)

