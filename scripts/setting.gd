
extends Control

@onready var connection: Node = get_node_or_null("../../Connection")
@onready var top_edge_area = $TopEdgeArea
@onready var option_panel: PanelContainer = $OptionPanel
@onready var content_host: Control = $ContentHost
@onready var active_mode_host: Control = get_node_or_null("../ActiveModeHost") as Control
@onready var option_buttons: HBoxContainer = $OptionPanel/ButtonMargins/OptionButtons
@onready var mode_set_button: Button = $OptionPanel/ButtonMargins/OptionButtons/ModeSetButton
@onready var addon_set_button: Button = $OptionPanel/ButtonMargins/OptionButtons/AddonSetButton
@onready var active_came_set_button: Button = (
	$OptionPanel/ButtonMargins/OptionButtons/ActiveCameSetButton
)
@onready var shade_set_button: Button = (
	$OptionPanel/ButtonMargins/OptionButtons/ShadeSetButton
)
@onready var preview_set_button: Button = (
	$OptionPanel/ButtonMargins/OptionButtons/PreviewSetButton
)

# ── 预览设置页打开时：强制停录制、强制 link，并隐藏这两个按钮 ──
@onready var record_button: Node = get_node_or_null("../RecordButton")
@onready var link_button: Node = get_node_or_null("../LinkButton")
@onready var _preview_connection: Node = get_node_or_null("../../Connection")

# 打开预览页前的 link 状态（true = 处于 unlink）
var _preview_saved_link_unlink: bool = false
# 预览页当前是否处于"打开"状态
var _preview_lock_active: bool = false
# ============================================================
# 选项面板唤出时，盖在 stream 上面的「半透明 + 模糊」遮罩
#
# shader:   resources/ui_blur_mask.gdshader
# 节点位置: scenes/main.tscn 的 **ModeContainer** 下面，是 Setting 的**兄弟节点**，
#           排在 ActiveModeHost 之后、RecordButton 之前。
#
# ⚠️ 位置 = 绘制顺序，它决定了「谁被糊、谁保持清晰」，不要随便挪：
#     排在它**前面**的  Stream / ActiveModeHost                 → 被糊
#     排在它**后面**的  RecordButton / LinkButton / Setting     → 清晰
#       （Setting 里含 OptionPanel、OptionButtons，以及 OptionButtons
#        唤出的其它 .tscn —— 它们挂在 Setting/ContentHost 下面，所以也在
#        模糊层之上）
#     QRCode 是 Main 的最后一个子节点，永远在最上层 → 完全不受影响
# ============================================================
@onready var blur_mask: ColorRect = get_node_or_null("../BlurMask") as ColorRect
# ⚠️ 抓屏节点：**必须和遮罩同开同关**，见 _set_mask_active() 的说明。
@onready var blur_back_buffer: BackBufferCopy = (
	get_node_or_null("../BlurBackBuffer") as BackBufferCopy
)
# 二维码页面。它一出现就说明还没扫码 / 掉线了，此时要立刻收起设置界面，
# 否则它的 Mask shader（也用 hint_screen_texture）会采到我们的遮罩。
@onready var qr_code: Control = get_node_or_null("../../QRCode") as Control

# ============================================================
# 按下这些按钮时不显示模糊遮罩
#
# 它们打开的都是「要看着背后的画面来操作」的页面（挑摄像机 / 调阴影 / 看预览），
# 压一层模糊反而看不清背景。面板和页面照常，只是把遮罩关掉。
#
# ⚠️ 模式触控区不受影响：面板一唤出，整个 *_mode.tscn 就已经隐藏了
#    （见文件开头 ActiveModeHost 那段说明），所以那些 *Area 本来就是隐藏的。
#
# 名字要和 OptionButtons 下的节点名一致；找不到的会被静默跳过。
# ============================================================
const NO_BLUR_BUTTONS: Array[String] = [
	"ActiveCameSetButton",  # 摄像机选择页（camera_select.tscn）
	"ShadeSetButton",       # 阴影设置页（待做）
	"PreviewSetButton",     # 预览设置页（待做）
	# TODO: 以后新增这类页面，把按钮名加在这里
]

# ============================================================
# OptionButtons 唤出时，把**当前模式场景**（*_mode.tscn）整体藏起来
#
# 模式场景运行时被实例化到 ActiveModeHost 下面，所以这里直接开关
# ActiveModeHost 自己的显示，不再按节点名去逐个找触控区域：
#     OptionButtons 唤出 → 整块淡出，动画结束后 visible = false
#     面板收起          → 重新淡入
#
# ⚠️ 好处：以后新增模式**完全不用改代码**（旧写法要往一个名字数组里
#    补一行，新模式的区域忘了补就一直失灵）。
#
# ⚠️ Stream 是 ActiveModeHost 的**兄弟节点**（都挂在 ModeContainer 下，
#    Stream 排在更前面），所以藏模式场景不影响视频流 ——
#    stream 照常可见，这是需求明确要求的。
#
# ⚠️ 为什么最后一定要真的 visible = false：modulate.a = 0 只是透明，
#    visible 的 Control 依然会吃触摸事件，模式场景的触控区会抢走
#    本该给设置界面的触摸。
# ============================================================

const HIDDEN_TOP := -200.0
const HIDDEN_BOTTOM := -10.0
const SHOWN_TOP := 0.0
const SHOWN_BOTTOM := 190.0
const ANIMATION_DURATION := 0.25

var current_mode_scene_path: String = ""
var panel_tween: Tween


func _ready() -> void:
	# 模式场景等用户选项统一由 Options 单例管理
	current_mode_scene_path = Options.get_mode_scene_path()

	if connection == null:
		push_error("[Setting] 找不到 Connection 节点")
	else:
		print("[Setting] Connection 节点连接成功")

	top_edge_area.swipe_down.connect(_show_option_panel)
	top_edge_area.swipe_up.connect(_hide_option_panel)
	mode_set_button.toggled.connect(_on_mode_set_toggled)
	addon_set_button.toggled.connect(_on_addon_set_toggled)
	active_came_set_button.toggled.connect(_on_active_came_set_toggled)
	shade_set_button.toggled.connect(_on_shade_set_toggled)
	preview_set_button.toggled.connect(_on_preview_set_toggled)

	# 上面那几个「不要模糊」的按钮：按下/松开时重新决定遮罩要不要显示
	for button_name in NO_BLUR_BUTTONS:
		var button := option_buttons.get_node_or_null(button_name) as Button

		if button == null:
			push_warning(
				"[Setting] OptionButtons 里找不到 %s，NO_BLUR_BUTTONS 跳过它"
				% button_name
			)
			continue

		button.toggled.connect(_on_no_blur_button_toggled)

	option_panel.visible = false
	option_panel.modulate.a = 0.0

	# 模糊遮罩：初始隐藏，并且**同时把抓屏也关掉**（原因见 _set_mask_active）。
	# 参数先按 Options 里的值写一次，之后手机上改了值会走
	# Options.changed → _on_option_changed()，实时生效。
	if blur_mask != null:
		blur_mask.modulate.a = 0.0

	_set_mask_active(false)
	_apply_mask_params()
	Options.changed.connect(_on_option_changed)

	# 二维码页面（还没扫码 / 掉线）出现时立刻收起设置界面
	if qr_code != null:
		qr_code.visibility_changed.connect(_on_qr_visibility_changed)


func send_setting(setting_name: String, value: Variant) -> void:
	if connection == null:
		push_error("[Setting] 找不到 Connection 节点")
		return

	connection.call("send_setting", setting_name, value)


func _show_option_panel() -> void:
	_stop_animation()

	option_panel.visible = true

	# 背后那层模糊遮罩：先决定要不要显示（按着「不要模糊」的按钮时不显示），
	# 再和面板一起淡入。它盖住 stream 和模式场景，但盖不住
	# RecordButton / LinkButton / OptionPanel 以及唤出的页面（见文件开头说明）。
	_refresh_blur_mask()
	_apply_mask_params()

	panel_tween = create_tween()
	panel_tween.set_parallel(true)

	panel_tween.tween_property(option_panel, "offset_top", SHOWN_TOP, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "offset_bottom", SHOWN_BOTTOM, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "modulate:a", 1.0, ANIMATION_DURATION)

	if blur_mask != null:
		panel_tween.tween_property(blur_mask, "modulate:a", 1.0, ANIMATION_DURATION)

	# 当前模式场景整体淡出（动画跑完由 _finish_show 置 visible = false）。
	# 只藏它自己，兄弟节点 Stream 不受影响，视频流照常可见。
	if active_mode_host != null:
		panel_tween.tween_property(
			active_mode_host, "modulate:a", 0.0, ANIMATION_DURATION
		)

	panel_tween.chain().tween_callback(Callable(self, "_finish_show"))


func _hide_option_panel() -> void:
	_stop_animation()

	panel_tween = create_tween()
	panel_tween.set_parallel(true)

	panel_tween.tween_property(option_panel, "offset_top", HIDDEN_TOP, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "offset_bottom", HIDDEN_BOTTOM, ANIMATION_DURATION)
	panel_tween.tween_property(option_panel, "modulate:a", 0.0, ANIMATION_DURATION)

	if blur_mask != null:
		panel_tween.tween_property(blur_mask, "modulate:a", 0.0, ANIMATION_DURATION)

	# 模式场景重新淡入（先确保 visible，否则淡了也看不见）
	if active_mode_host != null:
		active_mode_host.visible = true

		panel_tween.tween_property(
			active_mode_host, "modulate:a", 1.0, ANIMATION_DURATION
		)

	panel_tween.chain().tween_callback(Callable(self, "_finish_hide"))


func _stop_animation() -> void:
	if panel_tween != null and panel_tween.is_running():
		panel_tween.kill()


## 面板唤出动画跑完（模式场景已经淡出）→ 把模式场景彻底置为不可见。
##
## 必须真的 visible = false：透明但 visible 的 Control 依然会吃触摸事件，
## 模式场景的触控区会抢走本该给设置界面的触摸。
## 只影响模式场景，Stream 是它的兄弟节点，一直可见。
func _finish_show() -> void:
	if active_mode_host != null:
		active_mode_host.visible = false


func _finish_hide() -> void:
	option_panel.visible = false

	# 遮罩的淡出已经由 _hide_option_panel() 的 tween 做完，这里彻底关掉。
	# ⚠️ _set_mask_active(false) 会**同时关掉抓屏**，这一步必须做，
	#    否则二维码页面外围会被我们这块 back buffer 影响（见其说明）。
	_set_mask_active(false)

	for child in content_host.get_children():
		child.queue_free()

	# 预览页如果还开着，面板隐藏时也要恢复按钮与 link 状态
	_exit_preview_lock()

	# ⚠️ 要把 OptionButtons 里的按钮**全部**弹起来，不能只弹模式按钮：
	#    按着 ShadeSet / AddonSet / ActiveCameSet 之类往上滑把面板收起时，
	#    那个按钮会一直停在「按下」的样子，下次唤出面板就是「按钮亮着
	#    但 ContentHost 里没有内容」，还得再点两下才回到正常。
	_unpress_option_buttons()

	print("[Setting] OptionPanel 已隐藏，设置界面已关闭")


## 把 OptionButtons 里的按钮全部弹起来（不触发 toggled 信号）。
##
## ⚠️ 用 set_pressed_no_signal()：这里只是「复位界面」，
##    不能当成用户按下，否则会连带去实例化 / 销毁页面。
func _unpress_option_buttons() -> void:
	for child in option_buttons.get_children():
		if child is Button:
			(child as Button).set_pressed_no_signal(false)
	
	
func _on_mode_set_toggled(is_toggled: bool) -> void:
	# 模式场景的隐藏/恢复由 _show_option_panel() / _finish_show() 统一处理，
	# 这里只负责模式选择面板自己的内容。
	for child in content_host.get_children():
		child.queue_free()

	if not is_toggled:
		print("[Setting] 已收起 ModeSelect")
		return

	var mode_scene := load(
		"res://scenes/mode_select.tscn"
	) as PackedScene

	if mode_scene == null:
		push_error("[Setting] 找不到 res://scenes/mode_select.tscn")
		return

	var mode_instance := mode_scene.instantiate() as Control

	if mode_instance == null:
		push_error("[Setting] ModeSelect 实例化失败")
		return

	mode_instance.connect(
		"mode_selected",
		Callable(self, "_on_mode_selected")
	)
	
	mode_instance.set("current_mode_scene_path",current_mode_scene_path)

	content_host.add_child(mode_instance)
	print("[Setting] 已打开 ModeSelect")
	
	
func _on_mode_selected(scene_path: String) -> void:
	if active_mode_host == null:
		push_error("[Setting] 找不到 ActiveModeHost")
		return

	var packed_scene := load(scene_path) as PackedScene

	if packed_scene == null:
		push_error("[Setting] 无法加载模式场景：" + scene_path)
		return

	var mode_instance := packed_scene.instantiate() as Control

	if mode_instance == null:
		push_error("[Setting] 模式场景实例化失败：" + scene_path)
		return

	for child in active_mode_host.get_children():
		child.queue_free()

	active_mode_host.add_child(mode_instance)
	
	current_mode_scene_path = scene_path
	Options.set_mode_scene_path(scene_path)

	for child in content_host.get_children():
		child.queue_free()

	mode_set_button.set_pressed_no_signal(false)

	# 新实例化出来的模式场景默认是 visible 的，但这时面板还开着，
	# 而 ActiveModeHost 已经被 _finish_show() 置成 visible = false，
	# 子节点会跟着不显示，所以这里不用额外处理；
	# 等面板收起时 _hide_option_panel() 会把整块淡入回来。

	print("[Setting] 已切换模式：", scene_path)


func _on_addon_set_toggled(is_toggled: bool) -> void:
	for child in content_host.get_children():
		child.queue_free()

	if not is_toggled:
		print("[Setting] 已关闭 AddonSet")
		return

	var packed_scene := load(
		"res://scenes/addon_set.tscn"
	) as PackedScene

	if packed_scene == null:
		push_error("[Setting] 找不到 addon_set.tscn")
		return

	var page := packed_scene.instantiate() as Control

	if page == null:
		push_error("[Setting] AddonSet.tscn 的根节点必须是 Control")
		return

	content_host.add_child(page)
	print("[Setting] 已打开 AddonSet")


## 点 ActiveCameSetButton 时调用：把 camera_select.tscn 实例化到 ContentHost 下面。
##
## 和 _on_addon_set_toggled 一样 —— 这些按钮共用一个 ButtonGroup，
## 所以按下这个会自动松开其它按钮，那边清空 content_host 的行会先跑，
## 这里再加新页面，同一时刻只有一个页面在。
func _on_active_came_set_toggled(is_toggled: bool) -> void:
	for child in content_host.get_children():
		child.queue_free()

	if not is_toggled:
		print("[Setting] 已关闭 CameraSelect")
		return

	var packed_scene := load(
		"res://scenes/camera_select.tscn"
	) as PackedScene

	if packed_scene == null:
		push_error("[Setting] 找不到 camera_select.tscn")
		return

	var page := packed_scene.instantiate() as Control

	if page == null:
		push_error("[Setting] camera_select.tscn 的根节点必须是 Control")
		return

	content_host.add_child(page)
	print("[Setting] 已打开 CameraSelect")


## 点 ShadeSetButton 时调用：把 shade_set_page.tscn 实例化到 ContentHost 下面。
##
## 和上面几个一样 —— 这些按钮共用一个 ButtonGroup，按下这个会自动松开
## 其它按钮，那边清空 content_host 的行会先跑，这里再加新页面，
## 同一时刻只有一个页面在。
##
## ⚠️ 这个页面本身不需要额外喂数据：它自己从 Options 读 Blender 推来的着色状态，
##    并且会主动向 Blender 要一次（见 scripts/shade_set_page.gd）。
func _on_shade_set_toggled(is_toggled: bool) -> void:
	for child in content_host.get_children():
		child.queue_free()

	if not is_toggled:
		print("[Setting] 已关闭 ShadeSet")
		return

	var packed_scene := load(
		"res://scenes/shade_set_page.tscn"
	) as PackedScene

	if packed_scene == null:
		push_error("[Setting] 找不到 shade_set_page.tscn")
		return

	var page := packed_scene.instantiate() as Control

	if page == null:
		push_error("[Setting] shade_set_page.tscn 的根节点必须是 Control")
		return

	content_host.add_child(page)
	print("[Setting] 已打开 ShadeSet")


## 点 PreviewSetButton 时调用：把 preview_set_page.tscn 实例化到 ContentHost 下面。
##
## 和其它 *_set_page 一样：
##   - 共用 ButtonGroup，同一时刻只有一个页面 ✓
##   - OptionPanel 收起时 _finish_hide() 会清空 content_host → 页面跟着隐藏 ✓
func _on_preview_set_toggled(is_toggled: bool) -> void:
	for child in content_host.get_children():
		child.queue_free()

	if not is_toggled:
		print("[Setting] 已关闭 PreviewSet")
		_exit_preview_lock()
		return

	var packed_scene := load(
		"res://scenes/preview_set_page.tscn"
	) as PackedScene

	if packed_scene == null:
		push_error("[Setting] 找不到 preview_set_page.tscn")
		return

	var page := packed_scene.instantiate() as Control

	if page == null:
		push_error("[Setting] preview_set_page.tscn 的根节点必须是 Control")
		return

	content_host.add_child(page)
	print("[Setting] 已打开 PreviewSet")

	_enter_preview_lock()


# ============================================================
# 背景模糊遮罩（resources/ui_blur_mask.gdshader）
#
# 作用范围：盖住 stream 和当前模式画面，但**不**影响
#           RecordButton / LinkButton / OptionPanel（含 OptionButtons）
#           以及 OptionButtons 唤出的其它 .tscn。
#           （靠节点绘制顺序实现，详见文件开头 blur_mask 的说明）
#
# 三个参数都存在 Options 里（登记在 options.gd 的 DEFAULTS）：
#   "blur_mask/opacity"    半透明程度  0.0 ~ 1.0        ← 手机上调「半透明」
#   "blur_mask/radius"     模糊半径    单位 = 屏幕像素   ← 手机上调「模糊程度」
#   "blur_mask/ring_taps"  采样圈数    1 ~ 4（性能 vs 平滑度）
#
# 【手机上想调怎么办】
#   改 Options 里这三个值即可，例如设置页放三个滑条：
#       Options.set_value("blur_mask/opacity", slider.value)
#       Options.set_value("blur_mask/radius", slider.value)
#   写入会广播 Options.changed → 下面的 _on_option_changed() 立刻把新值
#   塞进 shader，不需要重启、不用重建场景。
#
#   ⚠️ 临时试验时如果直接改 options.gd 的 DEFAULTS 却发现没效果：
#      存档里的旧值会盖掉默认值。先删掉 user://blecaco_settings.cfg，
#      或者调用一次 Options.reset_to_defaults()。
#
#   另外两个不在 Options 里、需要改代码的参数：
#     遮罩颜色 mask_color —— 在 .gdshader 文件里改
#     遮罩覆盖范围       —— 由 main.tscn 里 BlurMask 节点的锚点决定
#                          （现在是全屏；想让画面某一块保持清晰就缩小它。
#                          注意它只决定「哪些像素被糊」，面板永远在最上层）
# ============================================================


## 把 Options 里的参数写进遮罩的 ShaderMaterial。
## ⚠️ 参数一律在这里设置，**不要**写进 .tscn 的 shader_parameter/xxx ——
##    那会覆盖 shader 文件里的默认值，以后改 shader 就不生效了。
func _apply_mask_params() -> void:
	if blur_mask == null:
		return

	var mask_material := blur_mask.material as ShaderMaterial

	if mask_material == null:
		push_warning("[Setting] BlurMask 上没有 ShaderMaterial")
		return

	mask_material.set_shader_parameter(
		"mask_opacity",
		Options.get_float("blur_mask/opacity")
	)
	mask_material.set_shader_parameter(
		"blur_radius",
		Options.get_float("blur_mask/radius")
	)
	mask_material.set_shader_parameter(
		"ring_taps",
		Options.get_int("blur_mask/ring_taps")
	)


## Options 里任意选项变化时调用；只关心遮罩那三个。
func _on_option_changed(a_key: String, _a_value: Variant) -> void:
	if not a_key.begins_with("blur_mask/"):
		return

	_apply_mask_params()


## 按下 / 松开 NO_BLUR_BUTTONS 里的按钮时调用：重新决定遮罩要不要显示。
func _on_no_blur_button_toggled(_is_toggled: bool) -> void:
	_refresh_blur_mask()


## 重新决定模糊遮罩要不要显示。
##
##   面板没打开                        → 不显示
##   面板开着，但按着「不要模糊」的按钮 → 不显示（面板和页面照常）
##   其余情况                          → 显示
##
## ⚠️ 这里直接开 / 关，不走淡入淡出：面板那串 tween 正在动 blur_mask 的 alpha，
##    再叠一个 tween 会互相打架。
func _refresh_blur_mask() -> void:
	if not option_panel.visible:
		_set_mask_active(false)
		return

	_set_mask_active(not _is_any_no_blur_button_pressed())


## 是否按着 NO_BLUR_BUTTONS 里的任意一个按钮。
func _is_any_no_blur_button_pressed() -> bool:
	for button_name in NO_BLUR_BUTTONS:
		var button := option_buttons.get_node_or_null(button_name) as Button

		if button != null and button.button_pressed:
			return true

	return false


## 统一开关「模糊遮罩 + 抓屏」这一层。
## ⚠️ 为什么不能只改 blur_mask.visible —— BackBufferCopy 是**全场景生效**的：
##    只要它处于启用状态，之后所有用到 hint_screen_texture 的 shader 都会
##    采到这块 back buffer。而二维码页面的 Mask shader
##    （resources/qrcode.gdshader）正是用它来做外围那圈「模糊背景」的，
##    所以抓屏一开，二维码页面的外观就被改掉了。
##
##    实测（1920x1080，逐像素比对，二维码页面外围同一点）：
##      copy_mode = VIEWPORT (2)  → 0.133
##      copy_mode = DISABLED (0)  → 0.082
##    其中 DISABLED 的结果与「场景里根本没有这个节点」**逐像素完全一致**。
##    因此默认必须是 DISABLED，只在遮罩真要显示时才切成 VIEWPORT。
func _set_mask_active(active: bool) -> void:
	if blur_mask != null:
		blur_mask.visible = active

	if blur_back_buffer != null:
		blur_back_buffer.copy_mode = (
			BackBufferCopy.COPY_MODE_VIEWPORT
			if active
			else BackBufferCopy.COPY_MODE_DISABLED
		)


## 二维码页面显示 / 隐藏时调用。
##
## 还没扫码、或 Blender 掉线时，二维码页面会重新出现。此时如果设置界面
## （连同遮罩和抓屏）还开着，二维码页面外围就会采到遮罩，外观被改掉 ——
## 所以这里**立刻**收起设置界面（不走 0.25s 动画，避免中间有几十毫秒的错位）。
func _on_qr_visibility_changed() -> void:
	if qr_code == null or not qr_code.visible:
		return

	if not option_panel.visible:
		return

	_stop_animation()

	option_panel.visible = false
	option_panel.modulate.a = 0.0
	option_panel.offset_top = HIDDEN_TOP
	option_panel.offset_bottom = HIDDEN_BOTTOM

	_set_mask_active(false)

	for child in content_host.get_children():
		child.queue_free()

	_unpress_option_buttons()

	# 面板是被强制收起的，不走淡入动画 —— 模式场景立刻恢复可见
	if active_mode_host != null:
		active_mode_host.visible = true
		active_mode_host.modulate.a = 1.0

	print("[Setting] 二维码页面出现，已立刻收起设置界面")


# ============================================================
# 预览设置页打开时的按钮锁定
#
# 打开：
#   - 不管录制状态如何 → 强制停止录制
#   - 不管 link 状态如何 → 强制恢复 link（取消 unlink）
#   - 隐藏 RecordButton / LinkButton
# 关闭：
#   - 重新显示两个按钮
#   - 录制状态**不恢复**（保持停止）
#   - link 状态**恢复到打开预览页之前**
# ============================================================

func _enter_preview_lock() -> void:
	if _preview_lock_active:
		return

	_preview_lock_active = true

	# 1. 记住 LinkButton 的**显示状态**（不改它）
	if link_button != null:
		_preview_saved_link_unlink = bool(link_button.get("button_pressed"))
		link_button.visible = false

	# 2. 暂停向 Blender 发送 action（旋转 / 位移都停）
	if _preview_connection != null and _preview_connection.has_method("set_action_sending_enabled"):
		_preview_connection.call("set_action_sending_enabled", false)

	# 3. 强制停止录制并隐藏 RecordButton
	if record_button != null:
		record_button.visible = false

		if bool(record_button.get("is_recording")):
			record_button.call("_on_pressed")

	# 4. 暂停当前模式的推流画面旋转（只有 car_mode 有这个接口）
	_set_active_stream_rotation(false)

	print("[Setting] 打开预览页：已暂停发送 action、停止录制")


func _exit_preview_lock() -> void:
	if not _preview_lock_active:
		return

	_preview_lock_active = false

	# 1. 重新显示按钮（录制状态保持停止，不恢复）
	if record_button != null:
		record_button.visible = true

	# 2. LinkButton 显示状态保持和隐藏之前一样（只同步视觉）
	if link_button != null:
		link_button.visible = true
		link_button.call("set_pressed_no_signal", _preview_saved_link_unlink)

	# 3. 按 LinkButton 的显示状态决定是否恢复发送：
	#    显示 unlink（_preview_saved_link_unlink = true）→ 保持暂停
	#    显示 link  → 恢复发送
	if _preview_connection != null and _preview_connection.has_method("set_action_sending_enabled"):
		_preview_connection.call(
			"set_action_sending_enabled",
			not _preview_saved_link_unlink
		)

	# 4. 恢复推流画面旋转
	_set_active_stream_rotation(true)

	print(
		"[Setting] 关闭预览页：发送状态恢复为",
		"暂停" if _preview_saved_link_unlink else "继续"
	)


## 对当前活动模式设置"推流画面旋转"开关（只有 car_mode 实现了该方法）
func _set_active_stream_rotation(enabled: bool) -> void:
	if active_mode_host == null or not is_instance_valid(active_mode_host):
		return

	for mode in active_mode_host.get_children():
		if mode.has_method("set_stream_rotation_enabled"):
			mode.call("set_stream_rotation_enabled", enabled)
