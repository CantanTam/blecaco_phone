extends Control

# ============================================================
# 着色设置页（底部一排圆形按钮）
#
# 结构完全对齐 main.tscn 里的 OptionPanel（见 shade_set_page.tscn 的说明）：
#     OptionPanel (PanelContainer)
#       └ ButtonMargins (MarginContainer)
#           └ OptionButtons (HBoxContainer)
#               └ XRay / ShadingWire / ShadingSolid / ShadingTexture / ShadingRendered
#
# 外观（150px 圆、间距 50、四个 StyleBoxFlat）都在场景里，和顶部那排按钮同一套值。
# 图标留空，后期自己往按钮的 icon 属性里加。
#
# ------------------------------------------------------------
# 与 Blender 的双向同步（Blender 侧见 blecaco/setting.py 的着色那一段）
#
# 手机 → Blender：按按钮 → 发 setting/shading，value 是目标状态
#                 （"XRAY" / "WIREFRAME" / "SOLID" / "MATERIAL" / "RENDERED"）
# Blender → 手机：Blender 改完**立刻**回推一次；用户在 Blender 里自己点
#                 X-Ray 或改着色方式，也会在半秒内推过来。
#                 新客户端（手机刚扫完二维码）接入时还会整组补发一次做基准。
#
# ⚠️ 所以这里**不做乐观更新**（和 camera_select.gd 一样）：
#    按钮的按下状态一律由 Blender 推来的值决定，
#    万一 Blender 那边没做成功（例如当前窗口没有 3D 视图），
#    回推的状态会让按钮自己弹回去，不会出现「手机显示已选中、Blender 却没变」。
# ============================================================

## 按钮节点名 → 发给 Blender 的 value。
## value 的含义和 Blender 那边一一对应（见 blecaco/setting.py）：
##     XRAY                → bpy.ops.view3d.toggle_xray()
##     WIREFRAME/SOLID/MATERIAL/RENDERED → space.shading.type
## ⚠️ 节点名变了这里也要跟着改（场景里的按钮名就是这几个）。
const BUTTON_VALUES := {
	"XRay": "XRAY",
	"ShadingWire": "WIREFRAME",
	"ShadingSolid": "SOLID",
	# 按钮叫 Texture，对应 Blender 的 MATERIAL 材质预览
	"ShadingTexture": "MATERIAL",
	"ShadingRendered": "RENDERED",
}

## X-Ray 按钮的节点名。它和另外四个不一样：
##     · 它是独立的开关（不在 ButtonGroup 里）
##     · Blender 那边是 toggle 操作 → 按下去和弹起来都要发一次
const XRAY_NAME := "XRay"

## 发给 Blender 的 setting 名。
## value = 上面那些字符串 → 改状态；value = null → 「把当前状态给我一份」。
const SHADING_SETTING := "shading"

## Options 里存 Blender 着色状态的键（由 main.gd 从 Blender 的推送写进来）。
## 结构：{"xray": false, "shading": "SOLID"}
const SHADING_KEY := "blender/shading"

@onready var option_buttons: HBoxContainer = $OptionPanel/ButtonMargins/OptionButtons
# 路径：ShadeSetPage → ContentHost → Setting → ModeContainer → Main → Connection
@onready var connection: Node = get_node_or_null("../../../../Connection")

## 节点名 → 按钮，初始化时填好，刷新状态时直接用
var _buttons: Dictionary = {}


func _ready() -> void:
	for button_name in BUTTON_VALUES.keys():
		var button := option_buttons.get_node_or_null(button_name) as Button

		if button == null:
			push_warning(
				"[ShadeSet] OptionButtons 里找不到 %s，跳过它" % button_name
			)
			continue

		button.toggled.connect(_on_button_toggled.bind(button_name))
		_buttons[button_name] = button

	# Blender 推来的着色状态变了 → 刷新按钮的按下状态
	Options.changed.connect(_on_options_changed)

	_refresh_buttons()

	# 打开页面时主动向 Blender 要一次当前状态。
	#
	# ⚠️ 光靠 Blender 那边「新客户端接入 / 状态变化时推」是不够的：
	#    手机早就在连线了（那个时机已经过去），这里要一次最稳。
	#    Blender 收到 value = null 会直接回推当前状态，不改任何东西。
	_request_state()


# ============================================================
# 与 Blender 同步
# ============================================================


## 主动请求一次当前着色状态。
func _request_state() -> void:
	if connection == null:
		# 还没连上：不报错，等 Blender 自己推
		return

	connection.call("send_setting", SHADING_SETTING, null)


## 发给 Blender 一个着色请求。
func _send(value: String) -> void:
	if connection == null:
		push_warning("[ShadeSet] 找不到 Connection，%s 没能发给 Blender" % value)
		return

	if not connection.call("send_setting", SHADING_SETTING, value):
		push_warning("[ShadeSet] 着色请求发送失败：%s" % value)
		return

	print("[ShadeSet] 已请求 Blender 切换着色：", value)


## 按钮被按下 / 弹起。
##
## ⚠️ X-Ray 是开关，按下和弹起都算一次点击，都要发；
##    另外四个在同一个 ButtonGroup 里，点新的那个会顺手把旧的弹起来
##    （旧的也会发一次 toggled(false)）—— 那次不能当成一次点击，否则会多发一个请求。
func _on_button_toggled(is_pressed: bool, button_name: String) -> void:
	if not is_pressed and button_name != XRAY_NAME:
		return

	_send(BUTTON_VALUES[button_name])


## Options 里任意选项变化时调用；只关心 Blender 推来的着色状态。
func _on_options_changed(a_key: String, _a_value: Variant) -> void:
	if a_key != SHADING_KEY:
		return

	_refresh_buttons()


## 按 Blender 推来的状态刷新五个按钮的按下状态（谁亮谁不亮）。
##
## 状态里没有 shading（比如还没收到过推送）时，四个着色按钮都不亮 ——
## 宁可什么都不亮，也不要显示一个和 Blender 不一致的状态。
func _refresh_buttons() -> void:
	var state := _shading_state()
	var shading := str(state.get("shading", ""))
	var xray := bool(state.get("xray", false))

	# ⚠️ 分两步、先灭后亮：
	#    先让「不该亮的」全部灭掉（包括组里原来亮着那个），
	#    再点亮目标 —— 否则 ButtonGroup 会自己再弹一次别的按钮，
	#    顺序反了最终状态可能不对。
	for button_name in _buttons.keys():
		if not _should_be_pressed(button_name, shading, xray):
			# ⚠️ 必须 no_signal：否则会被当成用户按下，
			#    又原样发回 Blender，两边来回弹。
			(_buttons[button_name] as Button).set_pressed_no_signal(false)

	for button_name in _buttons.keys():
		if _should_be_pressed(button_name, shading, xray):
			(_buttons[button_name] as Button).set_pressed_no_signal(true)


## 这个按钮在当前状态下该不该亮。
##     XRay            → X-Ray 开着就亮
##     另外四个        → 当前着色方式就是它对应的那个就亮
func _should_be_pressed(
	button_name: String,
	shading: String,
	xray: bool
) -> bool:
	if button_name == XRAY_NAME:
		return xray

	return BUTTON_VALUES[button_name] == shading


## 读 Blender 推来的着色状态（结构见文件开头）。
func _shading_state() -> Dictionary:
	var value: Variant = Options.get_value(SHADING_KEY, {})

	if value is Dictionary:
		return value

	return {}
