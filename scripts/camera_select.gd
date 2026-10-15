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

## 发给 Blender 的 setting 名：摄像机列表。
## 发一个 null 值过去 = 「把当前列表给我一份」（Blender 会立刻回推）。
const CAMERAS_SETTING := "cameras"

## 发给 Blender 的 setting 名：切换活动摄像机
const ACTIVE_CAMERA_SETTING := "active_camera"

## 模板行的节点名（场景里放着，用来复制出每一台摄像机）
const TEMPLATE_NAME := "CameraItem"

## 图标节点名
const ICON_NAME := "CameraIcon"

## 「点一下」的判定：按下到松开之间移动不超过这个距离（px）才算点击。
## 超过就当成列表滚动，不切摄像机。
const TAP_MAX_DISTANCE := 20.0

## 记录按下位置用的 meta 名（挂在行上）
const PRESS_POSITION_META := "press_position"


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

	# 打开页面时主动向 Blender 要一次当前列表。
	#
	# ⚠️ 光靠 Blender 那边「新客户端接入 / 状态变化时推」是不够的：
	#    手机早就在连线了（那个时机已经过去），这里要一次最稳。
	_request_camera_list()


## 主动请求一次摄像机列表（Blender 收到就回推 setting/cameras）。
func _request_camera_list() -> void:
	if connection == null:
		# 还没连上：不报错，等 Blender 自己推
		return

	connection.call("send_setting", CAMERAS_SETTING, null)


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

	# ⚠️ 一台摄像机都没有时**什么都不显示** —— 按需求不需要任何提示。
	if names.is_empty():
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

	# 整行可点：点一下就切到这台摄像机。
	# ⚠️ mouse_filter 由 SettingsStyle.style_item_bg() 设成 PASS ——
	#    既能收到 gui_input，又不会挡住外层 ScrollContainer 的滑动。
	var item_bg := row.find_child(
		SettingsStyle.ITEM_BG_NAME, true, false
	) as Control

	if item_bg != null:
		item_bg.gui_input.connect(
			_on_row_gui_input.bind(camera_name, item_bg)
		)


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


## 行被点 / 被摸时的处理。
##
## ⚠️ 只有「按下 → 松开之间几乎没移动」才算点击。
##    列表能滑动之后，手指拖动会先经过行上；如果一按下就切摄像机，
##    滑列表就会一路乱切。
func _on_row_gui_input(
	event: InputEvent,
	camera_name: String,
	item_bg: Control
) -> void:
	var position := Vector2.ZERO
	var is_press := false
	var is_release := false

	if event is InputEventScreenTouch:
		position = event.position
		is_press = event.pressed
		is_release = not event.pressed
	elif event is InputEventMouseButton:
		# ⚠️ Android 上开着「触摸 → 鼠标」模拟时，一次点按会额外发一遍鼠标事件；
		#    两条都处理的话点一次会切两次。模拟开着时只认触摸那条。
		if Input.is_emulating_mouse_from_touch():
			return

		if event.button_index != MOUSE_BUTTON_LEFT:
			return

		position = event.position
		is_press = event.pressed
		is_release = not event.pressed
	else:
		return

	# ⚠️ 必须换算成**屏幕坐标**再比较：
	#    gui_input 给的是控件局部坐标，而列表滑起来之后行会跟着手指一起移动，
	#    局部坐标里手指几乎没动 → 拖动会被误判成「点一下」，滑列表就一路乱切。
	var screen_position := (
		item_bg.get_global_transform_with_canvas() * position
	)

	if is_press:
		item_bg.set_meta(PRESS_POSITION_META, screen_position)
		return

	if not is_release:
		return

	var pressed_at: Variant = item_bg.get_meta(PRESS_POSITION_META, null)

	if pressed_at == null:
		return

	# 移动超过阈值 → 这是在滑列表，不是点这一行
	if (screen_position - (pressed_at as Vector2)).length() > TAP_MAX_DISTANCE:
		return

	_switch_to(camera_name)


## 请求 Blender 把某台摄像机设为活动摄像机。
##
## 不在这里做乐观更新：Blender 处理完会把新的摄像机状态推回来
## （见 blecaco/setting.py 的 _watch_state），页面收到再重建。
func _switch_to(camera_name: String) -> void:
	if connection == null:
		push_warning("[CameraSelect] 找不到 Connection，无法切换摄像机")
		return

	if not connection.call("send_setting", ACTIVE_CAMERA_SETTING, camera_name):
		push_warning("[CameraSelect] 切换摄像机请求发送失败")
		return

	print("[CameraSelect] 已请求切换活动摄像机：", camera_name)

