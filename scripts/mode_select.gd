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
const ANIMATION_DURATION := 0.21
const CENTER_POP_DURATION := 0.125

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

		cover.self_modulate = Color(1.0, 1.0, 1.0, 0.0)

		var cover_image: TextureRect = cover.get_node_or_null(
			"CoverImage"
		) as TextureRect

		if cover_image != null:
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
			selected_index,
			true
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
		cover.modulate = _get_cover_modulate(distance, 1.0, true)


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


func _get_cover_modulate(
	distance: int,
	alpha: float,
	highlight_center: bool = true
) -> Color:
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


func _get_step() -> float:
	return SIDE_CARD_SIZE.x + COVER_GAP


func _get_extra() -> float:
	return (MAIN_CARD_SIZE.x - SIDE_CARD_SIZE.x) / 2.0


func _get_cover_target(
	cover_index: int,
	selected_index: int,
	highlight_center: bool = true
) -> Dictionary:
	var distance: int = _get_cover_distance(
		cover_index,
		selected_index
	)

	var abs_distance: int = abs(distance)
	var center: Vector2 = cover_flow.size / 2.0

	var card_size: Vector2 = SIDE_CARD_SIZE

	if abs_distance == 0 and highlight_center:
		card_size = MAIN_CARD_SIZE

	# 所有卡片中心始终按 SIDE.x + GAP 的等距网格排布。
	# 只有真正高亮中心时，才把非中心卡片整体往外推
	# (MAIN.x - SIDE.x) / 2，保证中央放大后相邻卡片仍然
	# 保持 COVER_GAP 的间距。
	var step: float = _get_step()
	var horizontal_offset: float = 0.0

	if abs_distance >= 1:
		horizontal_offset = step * float(abs_distance)

		if highlight_center:
			horizontal_offset += _get_extra()

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

	if cover_name == selected_cover_name:
		print("[ModeSelect] 确认模式：", cover_name)
		mode_selected.emit(scene_path)
		return

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

	var step: float = _get_step()
	var extra: float = _get_extra()

	# direction < 0 时新封面从左侧滑入，先把它放到目标位置
	# 左侧 (step + extra) 处（完全透明），保证滑入过程中
	# 与相邻卡片之间的 COVER_GAP 恒定。
	if direction < 0:
		incoming_cover.position = (
			incoming_target["position"]
			+ Vector2(-(step + extra), 0.0)
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

	# 计算退出封面的滑出位移：
	# 直接读取内侧相邻卡片本次的实际位移，让两者同方向、同距离
	# 一起移动，这样它们之间的 COVER_GAP 保持恒定，速度也一致。
	# 内侧相邻卡片指的是更靠近中心的那张。
	var inner_neighbor_dir: int = 1 if direction > 0 else -1
	var inner_neighbor_index: int = (
		outgoing_index + inner_neighbor_dir + count
	) % count

	var inner_neighbor: Control = cover_flow.get_node_or_null(
		COVER_ORDER[inner_neighbor_index]
	) as Control

	var outgoing_move_x: float = -float(direction) * (step - extra)

	if inner_neighbor != null:
		var inner_target: Dictionary = _get_cover_target(
			inner_neighbor_index,
			new_index,
			false
		)
		outgoing_move_x = (
			inner_target["position"].x
			- inner_neighbor.position.x
		)

	# 其余封面一起线性移动 / 缩放 / 调亮度。
	# 滚动全程 highlight_center = false，保证经过中间时不放大、不高亮。
	var move_tween: Tween = create_tween()
	move_tween.set_parallel(true)

	for i in range(count):
		if i == outgoing_index:
			continue

		var cover: Control = cover_flow.get_node_or_null(
			COVER_ORDER[i]
		) as Control

		if cover == null:
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
		cover.pivot_offset = target_size / 2.0

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
			_get_cover_modulate(distance, 1.0, false),
			ANIMATION_DURATION
		).set_trans(Tween.TRANS_LINEAR)

	# 退出封面：用与其他卡片完全相同的持续时间和线性缓动滑出，
	# 同时淡出。这样它的移动速度不再偏快。
	var fade_out_tween: Tween = create_tween()
	fade_out_tween.set_parallel(true)

	fade_out_tween.tween_property(
		outgoing_cover,
		"modulate:a",
		0.0,
		ANIMATION_DURATION
	).set_trans(Tween.TRANS_LINEAR)

	fade_out_tween.tween_property(
		outgoing_cover,
		"position",
		outgoing_cover.position + Vector2(outgoing_move_x, 0.0),
		ANIMATION_DURATION
	).set_trans(Tween.TRANS_LINEAR)

	await fade_out_tween.finished

	# 完全透明后，将退出封面移到另一侧的最远位置。
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

	if move_tween.is_running():
		await move_tween.finished

	selected_cover_name = COVER_ORDER[new_index]


func _animate_center_cover() -> void:
	var selected_index: int = COVER_ORDER.find(
		selected_cover_name
	)

	if selected_index == -1:
		return

	# 所有封面一起 tween 到"高亮中心"的最终布局：只有被选中的那张
	# 放大 + 提亮，两侧卡片同步被推开，始终维持 COVER_GAP。
	var tween: Tween = create_tween()
	tween.set_parallel(true)

	for i in range(COVER_ORDER.size()):
		var cover: Control = cover_flow.get_node_or_null(
			COVER_ORDER[i]
		) as Control

		if cover == null:
			continue

		var target: Dictionary = _get_cover_target(
			i,
			selected_index,
			true
		)

		var target_size: Vector2 = target["size"]
		var target_position: Vector2 = target["position"]
		var distance: int = _get_cover_distance(
			i,
			selected_index
		)

		cover.z_index = target["z_index"]
		cover.pivot_offset = target_size / 2.0

		tween.tween_property(
			cover,
			"size",
			target_size,
			CENTER_POP_DURATION
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

		tween.tween_property(
			cover,
			"position",
			target_position,
			CENTER_POP_DURATION
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

		tween.tween_property(
			cover,
			"modulate",
			_get_cover_modulate(distance, 1.0, true),
			CENTER_POP_DURATION
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	await tween.finished
