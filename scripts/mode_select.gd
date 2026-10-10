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

const COVER_GAP := 30.0
const ANIMATION_DURATION := 0.42
const EDGE_FADE_DURATION := 0.24
const EDGE_MOVE_DISTANCE := 260.0

@onready var cover_flow: Control = $CoverFlow

var selected_cover_name: String = "FreeCover"
var cover_animation_running: bool = false


func _ready() -> void:
	await get_tree().process_frame

	_layout_covers()

	for cover_name in MODE_SCENES:
		var cover: Control = cover_flow.get_node_or_null(
			cover_name
		) as Control

		if cover == null:
			push_error("[ModeSelect] 找不到卡片：" + cover_name)
			continue

		# 隐藏 Panel 自身的背景，只显示封面图片。
		cover.self_modulate = Color(1.0, 1.0, 1.0, 0.0)

		var cover_image: TextureRect = cover.get_node_or_null(
			"CoverImage"
		) as TextureRect

		if cover_image != null:
			# 不再使用透视 Shader。
			cover_image.material = null
			cover_image.mouse_filter = Control.MOUSE_FILTER_IGNORE

		cover.mouse_filter = Control.MOUSE_FILTER_STOP

		cover.gui_input.connect(
			_on_cover_gui_input.bind(MODE_SCENES[cover_name])
		)


func _layout_covers() -> void:
	var selected_index: int = COVER_ORDER.find(
		selected_cover_name
	)

	for i in range(COVER_ORDER.size()):
		var cover: Control = cover_flow.get_node_or_null(
			COVER_ORDER[i]
		) as Control

		if cover == null:
			continue

		var target: Dictionary = _get_cover_target(
			i,
			selected_index
		)

		var target_size: Vector2 = target["size"]
		var target_position: Vector2 = target["position"]
		var distance: int = _get_cover_distance(
			i,
			selected_index
		)

		cover.size = target_size
		cover.position = target_position
		cover.pivot_offset = target_size / 2.0
		cover.rotation = 0.0
		cover.z_index = target["z_index"]
		cover.modulate = _get_cover_modulate(distance, 1.0,false)


func _get_cover_distance(
	cover_index: int,
	selected_index: int
) -> int:
	var count: int = COVER_ORDER.size()

	var distance: int = (
		cover_index - selected_index + count
	) % count

	if distance > int(count / 2):
		distance -= count

	return distance


func _get_cover_modulate(distance: int,alpha: float,highlight_center: bool = true) -> Color:
	var brightness: float = 0.45

	if distance == 0 and highlight_center:
		brightness = 1.0

	var final_alpha: float = alpha

	if abs(distance) >= 3:
		final_alpha = 0.0

	return Color(
		brightness,
		brightness,
		brightness,
		final_alpha
	)
	

func _get_cover_target(cover_index: int,selected_index: int,highlight_center: bool = true) -> Dictionary:
	var distance: int = _get_cover_distance(
	cover_index,
	selected_index
	)

	var abs_distance: int = abs(distance)
	var center: Vector2 = cover_flow.size / 2.0

	var card_size: Vector2 = SIDE_CARD_SIZE

	if abs_distance == 0 and highlight_center:
		card_size = MAIN_CARD_SIZE

	# 根据相邻卡片的实际宽度计算间距。
	# 即使中央卡片和两侧卡片尺寸不同，也不会相互重叠。
	var horizontal_offset: float = 0.0

	if abs_distance >= 1:
		horizontal_offset = (
			MAIN_CARD_SIZE.x / 2.0
			+ SIDE_CARD_SIZE.x / 2.0
			+ COVER_GAP
		)

	if abs_distance >= 2:
		horizontal_offset += (
			SIDE_CARD_SIZE.x + COVER_GAP
		)

	if abs_distance >= 3:
		horizontal_offset += (
			SIDE_CARD_SIZE.x + COVER_GAP
		)

	var direction: float = float(sign(distance))

	var card_center: Vector2 = Vector2(
		center.x + direction * horizontal_offset,
		center.y
	)

	return {
		"size": card_size,
		"position": card_center - card_size / 2.0,
		"z_index": 20 - abs_distance * 5
	}


func _on_cover_gui_input(
	event: InputEvent,
	scene_path: String
) -> void:
	var activated: bool = false

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

	var cover_name: String = ""

	for name in MODE_SCENES:
		if MODE_SCENES[name] == scene_path:
			cover_name = name
			break

	if cover_name.is_empty():
		return

	# 点击中央封面，确认当前模式。
	if cover_name == selected_cover_name:
		print("[ModeSelect] 确认模式：", cover_name)
		mode_selected.emit(scene_path)
		return

	# 点击其他封面，循环移动到中央。
	print("[ModeSelect] 滚动到中央：", cover_name)

	cover_animation_running = true
	await _animate_to_cover(cover_name)
	cover_animation_running = false

	print("[ModeSelect] 已居中：", cover_name)


func _animate_to_cover(cover_name: String) -> void:
	var target_index: int = COVER_ORDER.find(cover_name)

	if target_index == -1:
		return

	while selected_cover_name != cover_name:
		var current_index: int = COVER_ORDER.find(
			selected_cover_name
		)

		if current_index == -1:
			return

		var distance: int = _get_cover_distance(
			target_index,
			current_index
		)

		if distance == 0:
			break

		var direction: int = -1 if distance < 0 else 1

		await _animate_one_step(direction)

	# 所有循环移动结束后，目标封面才放大并高亮
	await _animate_center_cover()

func _animate_one_step(direction: int) -> void:
	var count: int = COVER_ORDER.size()

	var old_index: int = COVER_ORDER.find(
		selected_cover_name
	)

	if old_index == -1:
		return

	var half_count: int = int(count / 2)

	var new_index: int = (
		old_index + direction + count
	) % count

	# 找出即将从可视边缘离开的封面。
	var outgoing_index: int

	if direction > 0:
		outgoing_index = (
			old_index - (half_count - 1) + count
		) % count
	else:
		outgoing_index = (
			old_index + (half_count - 1)
		) % count

	# 最远的封面将从另一侧进入。
	var incoming_index: int = (
		old_index + half_count
	) % count

	var outgoing_cover: Control = cover_flow.get_node_or_null(
		COVER_ORDER[outgoing_index]
	) as Control

	var incoming_cover: Control = cover_flow.get_node_or_null(
		COVER_ORDER[incoming_index]
	) as Control

	if outgoing_cover == null or incoming_cover == null:
		push_error("[ModeSelect] 找不到循环所需的封面")
		return

	var outgoing_target: Dictionary = _get_cover_target(
		outgoing_index,
		new_index,
		false
	)

	var incoming_target: Dictionary = _get_cover_target(
		incoming_index,
		new_index,
		false
	)

	# 如果从右向左移动，将即将从左侧出现的封面
	# 在完全透明时移到目标位置，避免横穿整个屏幕。
	if direction < 0:
		# 先把封面放在最终位置的左侧，避免与原有封面重叠。
		# 随后的 Tween 会让它连续向右滑入。
		incoming_cover.position = (
			incoming_target["position"]
			+ Vector2(-SIDE_CARD_SIZE.x - COVER_GAP, 0.0)
		)

		incoming_cover.size = incoming_target["size"]
		incoming_cover.pivot_offset = incoming_cover.size / 2.0
		incoming_cover.z_index = incoming_target["z_index"]

		var incoming_distance: int = _get_cover_distance(
			incoming_index,
			new_index
		)

		incoming_cover.modulate = _get_cover_modulate(
			incoming_distance,
			0.0,
			false
		)

	# 其余封面连续移动、改变尺寸和亮度。
	var move_tween: Tween = create_tween()
	move_tween.set_parallel(true)

	for i in range(count):
		var cover: Control = cover_flow.get_node_or_null(
			COVER_ORDER[i]
		) as Control

		if cover == null:
			continue

		# 离场封面单独淡出，之后再移动到另一侧。
		if i == outgoing_index:
			continue

		var target: Dictionary = _get_cover_target(
			i,
			new_index,
			false
		)

		var target_size: Vector2 = target["size"]
		var target_position: Vector2 = target["position"]

		var distance: int = _get_cover_distance(
			i,
			new_index
		)

		cover.z_index = target["z_index"]

		move_tween.tween_property(
			cover,
			"position",
			target_position,
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_LINEAR)

		move_tween.tween_property(
			cover,
			"size",
			target_size,
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_LINEAR)

		move_tween.tween_property(
			cover,
			"modulate",
			_get_cover_modulate(distance, 1.0),
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_LINEAR)

	# 离场封面淡出，同时缓慢移出屏幕边缘。
	var edge_offset: float = (
		-float(direction) * EDGE_MOVE_DISTANCE
	)

	var fade_out_tween: Tween = create_tween()
	fade_out_tween.set_parallel(true)

	fade_out_tween.tween_property(
		outgoing_cover,
		"modulate:a",
		0.0,
		EDGE_FADE_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	fade_out_tween.tween_property(
		outgoing_cover,
		"position",
		outgoing_cover.position + Vector2(edge_offset, 0.0),
		EDGE_FADE_DURATION
	).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	await fade_out_tween.finished

	# 完全透明后，将离场封面放到最远位置。
	outgoing_cover.position = outgoing_target["position"]
	outgoing_cover.size = outgoing_target["size"]
	outgoing_cover.pivot_offset = outgoing_cover.size / 2.0
	outgoing_cover.z_index = outgoing_target["z_index"]

	var outgoing_distance: int = _get_cover_distance(
		outgoing_index,
		new_index
	)

	outgoing_cover.modulate = _get_cover_modulate(
		outgoing_distance,
		0.0,
		false
	)

	# 等待其余封面完成移动，防止连续点击时状态错乱。
	if move_tween.is_running():
		await move_tween.finished

	selected_cover_name = COVER_ORDER[new_index]
	
	
func _animate_center_cover() -> void:
	var selected_index: int = COVER_ORDER.find(
		selected_cover_name
	)

	if selected_index == -1:
		return

	var cover: Control = cover_flow.get_node_or_null(
		selected_cover_name
	) as Control

	if cover == null:
		return

	var center: Vector2 = cover_flow.size / 2.0
	var target_position: Vector2 = (
		center - MAIN_CARD_SIZE / 2.0
	)

	cover.pivot_offset = MAIN_CARD_SIZE / 2.0

	var tween: Tween = create_tween()
	tween.set_parallel(true)

	tween.tween_property(
		cover,
		"size",
		MAIN_CARD_SIZE,
		0.25
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	tween.tween_property(
		cover,
		"position",
		target_position,
		0.25
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	tween.tween_property(
		cover,
		"modulate",
		Color(1.0, 1.0, 1.0, 1.0),
		0.25
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	await tween.finished
