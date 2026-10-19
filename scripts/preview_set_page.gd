extends Control


@onready var home_button: Button = $PreviewPanel/ButtonMargin/PreviewButtons/HomeFrame
@onready var prev_button: Button = $PreviewPanel/ButtonMargin/PreviewButtons/PrevFrame
@onready var reverse_button: Button = $PreviewPanel/ButtonMargin/PreviewButtons/Reverse
@onready var play_button: Button = $PreviewPanel/ButtonMargin/PreviewButtons/Play
@onready var pause_button: Button = $PreviewPanel/ButtonMargin/PreviewButtons/Pause
@onready var next_button: Button = $PreviewPanel/ButtonMargin/PreviewButtons/NextFrame
@onready var end_button: Button = $PreviewPanel/ButtonMargin/PreviewButtons/EndFrame

@onready var connection: Node = get_node_or_null("../../../../Connection")


func _ready() -> void:
	# 原有：点 Reverse / Play 后切换成 Pause 按钮
	reverse_button.pressed.connect(_show_pause_button)
	play_button.pressed.connect(_show_pause_button)
	pause_button.pressed.connect(_show_playback_buttons)

	# 播放控制：把按钮翻译成 Blender 的 screen 操作
	home_button.pressed.connect(_send_preview_action.bind("home"))
	prev_button.pressed.connect(_send_preview_action.bind("prev"))
	reverse_button.pressed.connect(_send_preview_action.bind("reverse"))
	play_button.pressed.connect(_send_preview_action.bind("play"))
	next_button.pressed.connect(_send_preview_action.bind("next"))
	end_button.pressed.connect(_send_preview_action.bind("end"))
	pause_button.pressed.connect(_send_preview_action.bind("pause"))


## 把一个播放控制指令发给 Blender。
##
## 用 send_setting（type = "setting"）：预览页打开时 action 发送已被暂停，
## 但 setting 消息不受影响，所以这些按钮永远能到达 Blender。
func _send_preview_action(action: String) -> void:
	if connection == null:
		push_error("[PreviewSetPage] 找不到 Connection 节点")
		return

	if not connection.call("send_setting", "preview", action):
		push_error("[PreviewSetPage] 发送失败：" + action)


func _show_pause_button() -> void:
	reverse_button.hide()
	play_button.hide()
	pause_button.show()


func _show_playback_buttons() -> void:
	pause_button.hide()
	reverse_button.show()
	play_button.show()
