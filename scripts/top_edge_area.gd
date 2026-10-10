
extends Control

signal swipe_down
signal swipe_up

const SWIPE_THRESHOLD := 60.0

var touch_start_position := Vector2.ZERO
var tracking_touch := false


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			tracking_touch = get_global_rect().has_point(event.position)

			if tracking_touch:
				touch_start_position = event.position

		elif tracking_touch:
			_check_swipe(event.position)
			tracking_touch = false

	elif event is InputEventScreenDrag and tracking_touch:
		_check_swipe(event.position)


func _check_swipe(position: Vector2) -> void:
	var distance_x := position.x - touch_start_position.x
	var distance_y := position.y - touch_start_position.y

	if abs(distance_x) < SWIPE_THRESHOLD:
		return

	if abs(distance_x) <= abs(distance_y):
		return

	if distance_x > 0:
		print("[Setting] 检测到从左向右滑动")
		swipe_down.emit()
	else:
		print("[Setting] 检测到从右向左滑动")
		swipe_up.emit()

	tracking_touch = false
