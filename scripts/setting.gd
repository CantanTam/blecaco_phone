
extends Control

@onready var connection: Node = get_node_or_null("../../Connection")
@onready var top_edge_area = $TopEdgeArea
@onready var option_panel: PanelContainer = $OptionPanel
@onready var content_host: Control = $ContentHost
@onready var active_mode_host: Control = get_node_or_null("../ActiveModeHost") as Control
@onready var option_buttons: HBoxContainer = $OptionPanel/ButtonMargins/OptionButtons
@onready var mode_set_button: Button = $OptionPanel/ButtonMargins/OptionButtons/ModeSetButton
@onready var addon_set_button: Button = $OptionPanel/ButtonMargins/OptionButtons/AddonSetButton

# ============================================================
# 选项按钮按下时，需要暂时隐藏的「模式触控区域」
#
# 这些区域属于当前模式场景（*_mode.tscn），运行时被实例化到
# ActiveModeHost 下面，所以这里按 **节点名** 递归查找，不写死路径。
#
# ⚠️ 以后新增模式时**只改这个数组**即可：
#    把你的 *_mode.tscn 里的触控区域节点名照样补一行，例如
#        "DroneForwardArea",   # drone_mode.tscn
#    名字必须与场景里的节点名完全一致；
#    找不到的名字会被静默跳过（不报错，也不影响其它模式）。
# ============================================================
const HIDE_WHILE_OPTION_BUTTON_PRESSED: Array[String] = [
	"PlaneForwardArea",  # plane_mode.tscn  飞机前进触控区
	"CarForwardArea",    # car_mode.tscn    汽车前进触控区
	# TODO: 以后新增的模式区域加在下面，例如：
	# "DroneForwardArea",  # drone_mode.tscn
	# "GameForwardArea",   # game_mode.tscn
]

const HIDDEN_TOP := -200.0
const HIDDEN_BOTTOM := -10.0
const SHOWN_TOP := 0.0
const SHOWN_BOTTOM := 190.0
const ANIMATION_DURATION := 0.25

var current_mode_scene_path: String = ""
var panel_tween: Tween


func _ready() -> void:
	# 模式场景等用户选项统一由 Options 单例管理
	current_mode_scene_path = Options.get_mode_scene_path()

	if connection == null:
		push_error("[Setting] 找不到 Connection 节点")
	else:
		print("[Setting] Connection 节点连接成功")

	top_edge_area.swipe_down.connect(_show_option_panel)
	top_edge_area.swipe_up.connect(_hide_option_panel)
	mode_set_button.toggled.connect(_on_mode_set_toggled)
	addon_set_button.toggled.connect(_on_addon_set_toggled)

	# 统一接管 OptionButtons 下的**所有**按钮（不逐个写死名字）：
	# 只要还有按钮处于按下状态就隐藏模式触控区域，全部松开就恢复显示。
	# 这些按钮共用同一个 ButtonGroup，所以同一时刻最多只有一个被按下。
	for child in option_buttons.get_children():
		if child is Button:
			(child as Button).toggled.connect(_on_option_button_toggled)

	option_panel.visible = false
	option_panel.modulate.a = 0.0


func send_setting(setting_name: String, value: Variant) -> void:
	if connection == null:
		push_error("[Setting] 找不到 Connection 节点")
		return

	connection.call("send_setting", setting_name, value)


func _show_option_panel() -> void:
	_stop_animation()

	option_panel.visible = true

	panel_tween = create_tween()
	panel_tween.set_parallel(true)

	panel_tween.tween_property(option_panel, "offset_top", SHOWN_TOP, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "offset_bottom", SHOWN_BOTTOM, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "modulate:a", 1.0, ANIMATION_DURATION)


func _hide_option_panel() -> void:
	_stop_animation()

	panel_tween = create_tween()
	panel_tween.set_parallel(true)

	panel_tween.tween_property(option_panel, "offset_top", HIDDEN_TOP, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "offset_bottom", HIDDEN_BOTTOM, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "modulate:a", 0.0, ANIMATION_DURATION)

	panel_tween.chain().tween_callback(Callable(self, "_finish_hide"))


func _stop_animation() -> void:
	if panel_tween != null and panel_tween.is_running():
		panel_tween.kill()


func _finish_hide() -> void:
	option_panel.visible = false

	for child in content_host.get_children():
		child.queue_free()

	mode_set_button.set_pressed_no_signal(false)

	# set_pressed_no_signal() 不会发出 toggled 信号，所以这里手动刷新一次
	# 触控区域的显示状态（见 _refresh_mode_area_visibility 的说明）。
	_refresh_mode_area_visibility()

	print("[Setting] OptionPanel 已隐藏，设置界面已关闭")
	
	
func _on_mode_set_toggled(is_toggled: bool) -> void:
	# 模式触控区域的隐藏/恢复已经由 _on_option_button_toggled() 统一处理，
	# 这里只负责模式选择面板自己的内容。
	for child in content_host.get_children():
		child.queue_free()

	if not is_toggled:
		print("[Setting] 已收起 ModeSelect")
		return

	var mode_scene := load(
		"res://scenes/mode_select.tscn"
	) as PackedScene

	if mode_scene == null:
		push_error("[Setting] 找不到 res://scenes/mode_select.tscn")
		return

	var mode_instance := mode_scene.instantiate() as Control

	if mode_instance == null:
		push_error("[Setting] ModeSelect 实例化失败")
		return

	mode_instance.connect(
		"mode_selected",
		Callable(self, "_on_mode_selected")
	)
	
	mode_instance.set("current_mode_scene_path",current_mode_scene_path)

	content_host.add_child(mode_instance)
	print("[Setting] 已打开 ModeSelect")
	
	
func _on_mode_selected(scene_path: String) -> void:
	if active_mode_host == null:
		push_error("[Setting] 找不到 ActiveModeHost")
		return

	var packed_scene := load(scene_path) as PackedScene

	if packed_scene == null:
		push_error("[Setting] 无法加载模式场景：" + scene_path)
		return

	var mode_instance := packed_scene.instantiate() as Control

	if mode_instance == null:
		push_error("[Setting] 模式场景实例化失败：" + scene_path)
		return

	for child in active_mode_host.get_children():
		child.queue_free()

	active_mode_host.add_child(mode_instance)
	
	current_mode_scene_path = scene_path
	Options.set_mode_scene_path(scene_path)

	for child in content_host.get_children():
		child.queue_free()

	mode_set_button.set_pressed_no_signal(false)

	# 同上：无信号地改写了按下状态，必须手动刷新，
	# 否则会停留在"按钮已松开、触控区域却还隐藏着"的状态。
	_refresh_mode_area_visibility()

	print("[Setting] 已切换模式：", scene_path)


func _on_addon_set_toggled(is_toggled: bool) -> void:
	for child in content_host.get_children():
		child.queue_free()

	if not is_toggled:
		print("[Setting] 已关闭 AddonSet")
		return

	var packed_scene := load(
		"res://scenes/addon_set.tscn"
	) as PackedScene

	if packed_scene == null:
		push_error("[Setting] 找不到 addon_set.tscn")
		return

	var page := packed_scene.instantiate() as Control

	if page == null:
		push_error("[Setting] AddonSet.tscn 的根节点必须是 Control")
		return

	content_host.add_child(page)
	print("[Setting] 已打开 AddonSet")


# ============================================================
# 选项按钮 ↔ 模式触控区域
#
# 需求：OptionButtons 里任意按钮**按下去**时，把当前模式的触控区域
#      （如 PlaneForwardArea / CarForwardArea）隐藏起来，**松开**后再显示。
# 原因：这些区域铺满屏幕下半部分，会抢走本该给选项按钮的触摸事件。
#
# 实现要点：这些按钮共用同一个 ButtonGroup（toggle_mode），所以
# 「有没有按钮按着」只需要看是否还有 button_pressed 为 true 的按钮。
# 这样无论以后 OptionButtons 里加多少按钮，都不用改下面的代码。
# ============================================================


## OptionButtons 里任意按钮的按下状态变化时调用。
func _on_option_button_toggled(_is_toggled: bool) -> void:
	_refresh_mode_area_visibility()


## 重新计算并应用触控区域的显示状态。
##
## ⚠️ 一共有三个地方需要调用它：
##   1) 任意选项按钮的 toggled 信号 → _on_option_button_toggled()
##   2) 用 set_pressed_no_signal() 强制松开按钮之后
##      （它**不发信号**，不手动刷新就会一直停在被隐藏的状态）
##   3) 切换模式场景之后（新实例化出来的区域默认是 visible 的）
func _refresh_mode_area_visibility() -> void:
	_set_mode_areas_visible(not _is_any_option_button_pressed())


## 是否还有任意一个选项按钮处于按下状态。
func _is_any_option_button_pressed() -> bool:
	for child in option_buttons.get_children():
		if child is Button and (child as Button).button_pressed:
			return true

	return false


## 显示 / 隐藏所有登记在 HIDE_WHILE_OPTION_BUTTON_PRESSED 里的触控区域。
##
## 按节点名在 ActiveModeHost 子树里递归查找，所以：
##   - 不需要知道区域在当前模式场景里的层级
##   - 当前模式没有的区域会被跳过（找到 null 就 continue），不会报错
##   - 以后新增模式时，只要把区域节点名加进那个数组即可
func _set_mode_areas_visible(should_show: bool) -> void:
	if active_mode_host == null:
		return

	for area_name in HIDE_WHILE_OPTION_BUTTON_PRESSED:
		var area := active_mode_host.find_child(area_name, true, false) as Control

		if area == null:
			continue

		area.visible = should_show
