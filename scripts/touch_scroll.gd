extends ScrollContainer

# ============================================================
# 给 ScrollContainer 补上「手指拖动滚动」
#
# ⚠️ Godot 4 的 ScrollContainer 默认只认「滚轮」和「拖滚动条」，
#    触摸拖动它**完全没反应**（实测：在手机上合成 450px 的拖动，
#    scroll_vertical 仍然是 0）。所以这里自己实现最直白的那一套：
#    按下记录位置 → 拖动时把位移直接加减到 scroll_vertical / scroll_horizontal。
#
# 用法：给 ScrollContainer 挂上本脚本即可。
# ⚠️ 里面每一行的 mouse_filter 必须允许事件往上传递
#    （列表行的 ItemBg 由 SettingsStyle 设成 PASS），
#    否则事件在行上就被吃掉，这里收不到。
# ============================================================

## PC 上用鼠标拖也能滚（方便在编辑器里试）；手机上走触摸那条路
@export var mouse_drag_enabled := true

var _touch_index := -1
var _last_position := Vector2.ZERO

var _mouse_dragging := false


func _gui_input(event: InputEvent) -> void:
	# ---- 触摸（Android 走这条）----
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_index = event.index
			_last_position = event.position
		elif event.index == _touch_index:
			_touch_index = -1

		return

	if event is InputEventScreenDrag:
		if _touch_index != event.index:
			return

		var delta: Vector2 = event.position - _last_position
		_last_position = event.position

		_scroll_by(delta)
		accept_event()
		return

	# ---- 鼠标（PC 调试用）----
	# ⚠️ Android 上打开「触摸 → 鼠标」模拟后，一次拖动会同时产生
	#    触摸事件和模拟鼠标事件。两种情况下都跳过鼠标这条：
	#      · 触摸事件已经在处理（_touch_index != -1）
	#      · 系统正在把触摸模拟成鼠标
	#    否则会滚两倍。
	if _touch_index != -1 or not mouse_drag_enabled:
		return

	if Input.is_emulating_mouse_from_touch():
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_mouse_dragging = event.pressed
			_last_position = event.position

		return

	if event is InputEventMouseMotion and _mouse_dragging:
		var delta: Vector2 = event.position - _last_position
		_last_position = event.position

		_scroll_by(delta)
		accept_event()


## 手指往上滑（delta.y < 0）→ 内容往上走 → scroll_vertical 变大，
## 所以这里是「减去位移」。
func _scroll_by(delta: Vector2) -> void:
	if vertical_scroll_mode != SCROLL_MODE_DISABLED:
		scroll_vertical = int(scroll_vertical - delta.y)

	if horizontal_scroll_mode != SCROLL_MODE_DISABLED:
		scroll_horizontal = int(scroll_horizontal - delta.x)
