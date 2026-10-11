
extends Control

@onready var connection: Node = get_node_or_null("../../Connection")
@onready var top_edge_area = $TopEdgeArea
@onready var option_panel: PanelContainer = $OptionPanel
@onready var content_host: Control = $ContentHost
@onready var active_mode_host: Control = get_node_or_null("../ActiveModeHost") as Control
@onready var mode_set_button: Button = $OptionPanel/ButtonMargins/OptionButtons/ModeSetButton

const HIDDEN_TOP := -200.0
const HIDDEN_BOTTOM := -10.0
const SHOWN_TOP := 0.0
const SHOWN_BOTTOM := 190.0
const ANIMATION_DURATION := 0.25

const SETTINGS_FILE := "user://blecaco_settings.cfg"
const MODE_SECTION := "mode"
const MODE_KEY := "scene_path"
const DEFAULT_MODE_SCENE := "res://scenes/modes/free_mode.tscn"

const VALID_MODE_SCENE_PATHS := [
	"res://scenes/modes/free_mode.tscn",
	"res://scenes/modes/plane_mode.tscn",
	"res://scenes/modes/car_mode.tscn",
	"res://scenes/modes/game_mode.tscn",
	"res://scenes/modes/camera_mode.tscn",
	"res://scenes/modes/drone_mode.tscn"
]

var current_mode_scene_path: String = DEFAULT_MODE_SCENE
var panel_tween: Tween


func _ready() -> void:
	_load_saved_mode()
	if connection == null:
		push_error("[Setting] 找不到 Connection 节点")
	else:
		print("[Setting] Connection 节点连接成功")

	top_edge_area.swipe_down.connect(_show_option_panel)
	top_edge_area.swipe_up.connect(_hide_option_panel)
	mode_set_button.toggled.connect(_on_mode_set_toggled)

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
	
	
func _on_mode_set_toggled(is_toggled: bool) -> void:
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
	_save_current_mode()

	for child in content_host.get_children():
		child.queue_free()

	mode_set_button.set_pressed_no_signal(false)

	print("[Setting] 已切换模式：", scene_path)


func _load_saved_mode() -> void:
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_FILE)

	if error != OK:
		current_mode_scene_path = DEFAULT_MODE_SCENE

		if error != ERR_FILE_NOT_FOUND:
			push_warning("[Setting] 无法读取模式配置，使用 Free 模式")

		return

	var saved_path: String = str(
		config.get_value(
			MODE_SECTION,
			MODE_KEY,
			DEFAULT_MODE_SCENE
		)
	)

	if (
		VALID_MODE_SCENE_PATHS.has(saved_path)
		and ResourceLoader.exists(saved_path)
	):
		current_mode_scene_path = saved_path
	else:
		current_mode_scene_path = DEFAULT_MODE_SCENE


func _save_current_mode() -> void:
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_FILE)

	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_error("[Setting] 无法读取模式配置文件")
		return

	config.set_value(
		MODE_SECTION,
		MODE_KEY,
		current_mode_scene_path
	)

	error = config.save(SETTINGS_FILE)

	if error != OK:
		push_error("[Setting] 保存模式失败，错误代码：" + str(error))
		return

	print("[Setting] 已保存模式：", current_mode_scene_path)
