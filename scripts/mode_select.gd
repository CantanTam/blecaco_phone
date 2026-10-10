extends Control

signal mode_selected(scene_path: String)

const MODE_SCENES := {
	"FreeCover": "res://scenes/modes/free.tscn",
	"PlaneCover": "res://scenes/modes/plane.tscn",
	"CarCover": "res://scenes/modes/car.tscn",
	"GameCover": "res://scenes/modes/game.tscn",
	"CameraCover": "res://scenes/modes/camera.tscn",
	"DroneCover": "res://scenes/modes/drone.tscn"
}

# 卡片排列顺序
const COVER_ORDER := [
	"CameraCover",
	"PlaneCover",
	"FreeCover",
	"CarCover",
	"GameCover",
	"DroneCover"
]

const MAIN_CARD_SIZE := Vector2(560, 720)
const SIDE_CARD_SIZE := Vector2(460, 620)
const ANIMATION_DURATION := 0.45

@onready var cover_flow: Control = $CoverFlow

var selected_cover_name := "FreeCover"
var cover_animation_running := false


func _ready() -> void:
	await get_tree().process_frame

	_layout_covers()

	for cover_name in MODE_SCENES:
		var cover := cover_flow.get_node_or_null(cover_name) as Control

		if cover == null:
			push_error("[ModeSelect] 找不到卡片：" + cover_name)
			continue

		var cover_image := cover.get_node_or_null("CoverImage") as Control

		if cover_image != null:
			cover_image.mouse_filter = Control.MOUSE_FILTER_IGNORE

		cover.mouse_filter = Control.MOUSE_FILTER_STOP
		cover.gui_input.connect(
			_on_cover_gui_input.bind(MODE_SCENES[cover_name])
		)


func _layout_covers() -> void:
	var selected_index := COVER_ORDER.find(selected_cover_name)

	for i in range(COVER_ORDER.size()):
		var cover := cover_flow.get_node_or_null(
			COVER_ORDER[i]
		) as Control

		if cover == null:
			continue

		var target := _get_cover_target(i, selected_index)

		cover.size = target["size"]
		cover.position = target["position"]
		cover.pivot_offset = target["size"] / 2.0
		cover.rotation = target["rotation"]
		cover.z_index = target["z_index"]


func _get_cover_target(
	cover_index: int,
	selected_index: int
) -> Dictionary:
	var distance := cover_index - selected_index
	var count := COVER_ORDER.size()

	# 从另一侧绕回，让卡片始终围绕选中项排列
	if distance > count / 2:
		distance -= count
	elif distance < -count / 2:
		distance += count

	var abs_distance: int = abs(distance)
	var center := cover_flow.size / 2.0
	var card_size := SIDE_CARD_SIZE
	var horizontal_distance := 0.0
	var angle := 0.0

	if abs_distance == 0:
		card_size = MAIN_CARD_SIZE
	elif abs_distance == 1:
		horizontal_distance = 385.0
		angle = 0.0
	elif abs_distance == 2:
		horizontal_distance = 650.0
		angle = 0.0
	else:
		horizontal_distance = 850.0
		angle = 0.0

	var direction := float(sign(distance))

	var card_center := Vector2(
		center.x + direction * horizontal_distance,
		center.y + (0.0 if distance == 0 else 15.0)
	)

	var card_rotation := -direction * deg_to_rad(angle)

	return {
		"size": card_size,
		"position": card_center - card_size / 2.0,
		"rotation": card_rotation,
		"z_index": 20 - abs_distance * 5
	}


func _on_cover_gui_input(
	event: InputEvent,
	scene_path: String
) -> void:
	var activated := false

	if OS.has_feature("android"):
		if event is InputEventScreenTouch and event.pressed:
			activated = true
	else:
		if (
			event is InputEventMouseButton
			and event.button_index == MOUSE_BUTTON_LEFT
			and event.pressed
		):
			activated = true

	if not activated or cover_animation_running:
		return

	get_viewport().set_input_as_handled()

	var cover_name := ""

	for name in MODE_SCENES:
		if MODE_SCENES[name] == scene_path:
			cover_name = name
			break

	if cover_name.is_empty():
		return

	print("[ModeSelect] 点击卡片：", cover_name)

	cover_animation_running = true
	await _animate_to_cover(cover_name)
	cover_animation_running = false

	print("[ModeSelect] 动画完成：", scene_path)

	# 保留场景选择信号，之后由 Setting 接收并加载模式场景
	mode_selected.emit(scene_path)


func _animate_to_cover(cover_name: String) -> void:
	var selected_index := COVER_ORDER.find(cover_name)

	if selected_index == -1:
		return

	var tween := create_tween()
	tween.set_parallel(true)

	for i in range(COVER_ORDER.size()):
		var cover := cover_flow.get_node_or_null(
			COVER_ORDER[i]
		) as Control

		if cover == null:
			continue

		var target := _get_cover_target(i, selected_index)

		cover.pivot_offset = cover.size / 2.0
		cover.z_index = target["z_index"]

		tween.tween_property(
			cover,
			"position",
			target["position"],
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

		tween.tween_property(
			cover,
			"size",
			target["size"],
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

		tween.tween_property(
			cover,
			"pivot_offset",
			target["size"] / 2.0,
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

		tween.tween_property(
			cover,
			"rotation",
			target["rotation"],
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	await tween.finished

	selected_cover_name = cover_name
