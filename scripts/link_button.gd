extends Button

@onready var connection: Node = get_node_or_null(
	"../../Connection"
)

const LINK_ICON: Texture2D = preload(
	"res://resources/Link.svg"
)

const UNLINK_ICON: Texture2D = preload(
	"res://resources/Unlink.svg"
)


func _ready() -> void:
	# 启用按钮切换模式：点击后保持按下状态
	toggle_mode = true

	# 默认已连接：允许发送 action JSON
	button_pressed = false
	icon = LINK_ICON

	# 图标在按钮区域居中显示
	alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_alignment = HORIZONTAL_ALIGNMENT_CENTER

	if connection == null:
		push_error("[LinkButton] 找不到 Connection 节点")
		return

	# 确保初始状态允许发送 action
	connection.call(
		"set_action_sending_enabled",
		true
	)

	# 监听按钮状态切换
	toggled.connect(_on_toggled)


func _on_toggled(pressed_state: bool) -> void:
	if connection == null:
		return

	if pressed_state:
		# 按下：禁止发送 action JSON
		icon = UNLINK_ICON

		connection.call(
			"set_action_sending_enabled",
			false
		)

		print("[LinkButton] Action 发送已暂停")

	else:
		# 松开：恢复发送 action JSON
		icon = LINK_ICON

		connection.call(
			"set_action_sending_enabled",
			true
		)

		print("[LinkButton] Action 发送已恢复")
