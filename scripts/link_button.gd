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

# 相机旋转基准的保存/恢复走 free 模式的 action（真正驱动相机旋转的就是那条流）
const ROTATION_BASELINE_MODE: String = "free"


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

		# ⚠️ 必须赶在暂停**之前**发：connection.send_json() 会把
		#    action_sending_enabled == false 时的 action 消息直接丢掉。
		#    这条命令让 Blender 把相机当前旋转存起来，供重新 link 时当基准。
		_send_rotation_baseline_command("unlink")

		connection.call(
			"set_action_sending_enabled",
			false
		)

		print("[LinkButton] Action 发送已暂停")

	else:
		# 松开：恢复发送 action JSON
		icon = LINK_ICON

		# 先恢复发送（free_mode 收到 action_sending_changed(true) 会重新校准手机姿态），
		# 再通知 Blender 用保存的相机旋转当新基准 —— 同一帧内完成，中间不会漏发旋转。
		connection.call(
			"set_action_sending_enabled",
			true
		)

		_send_rotation_baseline_command("relink")

		print("[LinkButton] Action 发送已恢复")


## 给 Blender 发"保存/恢复相机旋转基准"命令（"unlink" / "relink"）
func _send_rotation_baseline_command(command: String) -> void:
	if connection == null:
		return

	if not connection.has_method("send_action"):
		push_error(
			"[LinkButton] Connection.send_action() 不存在"
		)
		return

	connection.call(
		"send_action",
		ROTATION_BASELINE_MODE,
		{"command": command}
	)
