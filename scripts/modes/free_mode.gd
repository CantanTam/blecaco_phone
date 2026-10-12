extends Node

const ROTATION_SEND_INTERVAL: float = 1.0 / 100.0

var rotation_sender = preload(
    "res://scripts/getrotation.gd"
).new()

var rotation_send_timer: float = 0.0
var connection_node: Node = null


func _ready() -> void:
	# 查找现有的 Connection 节点
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
	)

	if rotation_sender.is_available():
		print("[Orientation] Plugin loaded")
	else:
		push_error(
            "[Orientation] Plugin singleton not found"
		)

	if connection_node == null:
		push_error(
            "[Orientation] Connection node not found"
		)
	elif not connection_node.has_method("send_action"):
		push_error(
            "[Orientation] Connection.send_action() not found"
		)


func _process(delta: float) -> void:
	if not rotation_sender.has_orientation_data():
		return

	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	rotation_send_timer += delta

	if rotation_send_timer < ROTATION_SEND_INTERVAL:
		return

	rotation_send_timer = 0.0

	# 获取已经转换到 Blender Camera 坐标系的四元数
	var q: Quaternion = (
		rotation_sender.get_rotation_quaternion()
	)

	# 发送原始精度的四元数分量
	var quaternion_data: Dictionary = {
		"x": q.x,
		"y": q.y,
		"z": q.z,
		"w": q.w
	}

	# 通过现有 WebSocket 发送给 Blender
	var sent: bool = bool(
		connection_node.call(
			"send_action",
			"free",
			quaternion_data
		)
	)

	if sent:
		print(
			"[Orientation] Quaternion sent: ",
			"X=", snappedf(q.x, 0.01),
			" Y=", snappedf(q.y, 0.01),
			" Z=", snappedf(q.z, 0.01),
			" W=", snappedf(q.w, 0.01)
		)
