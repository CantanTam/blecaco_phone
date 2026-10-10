extends Control

@onready var connection: Node = get_node_or_null("../../Connection")

func _ready() -> void:
	if connection == null:
		push_error("[Setting] 找不到 Connection 节点")
	else:
		print("[Setting] Connection 节点连接成功")

func send_setting(setting_name: String, value: Variant) -> void:
	if connection == null:
		push_error("[Setting] 找不到 Connection 节点")
		return

	connection.call("send_setting", setting_name, value)
