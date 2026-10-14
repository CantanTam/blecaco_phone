extends Control

# ============================================================
# PlaneForwardArea：本区域的全部「表现」都集中在这里
# ============================================================
# 分工：
#   plane_forward_area.gd  遮罩 / 颜色 / 大小 / 渐变 / 按压反馈（本文件）
#   plane_mode.gd          只负责把姿态数据发给 Blender
#   plane_mode.tscn        只负责节点结构，不含任何视觉参数
#
# 场景里不再保存任何 shader_parameter：
# 所有参数都在本文件里定义，并在 _ready() 里推给 shader，
# 因此不会再出现「.tscn 覆盖 shader 默认值」导致改了没反应的问题。
# ============================================================

# ---------------- 变量设置（改这里就够）----------------
const FORWARD_SEND_INTERVAL: float = 0.01
const FORWARD_STEP_DISTANCE: float = 0.01

# 形状遮罩：两个材质共用同一张图
@export var mask_texture: Texture2D = preload(
	"res://resources/plane_forward.svg"
)

# 指尖光晕圆（ForwardColor）
@export var circle_size: float = 400.0                        # 直径（像素）
@export_range(0.0, 1.0) var gradient_start: float = 0.0       # 0=圆心起渐变, 1=圆周才起
@export_range(0.0, 1.0) var circle_alpha: float = 1.0         # 圆形透明度（1=不透明，0=看不见）

# ---- 圆形颜色分段 ----
# 坐标基准：以本区域「底边」为 y = 0，向上为正
const COLOR_GREEN := Color(0.0, 1.0, 0.0)
const COLOR_YELLOW := Color(1.0, 1.0, 0.0)
const COLOR_RED := Color(1.0, 0.0, 0.0)

const Y_GREEN_END := 350.0       # 0   ~ 350   纯绿
const Y_GREEN_TO_YELLOW := 515.0 # 350 ~ 515   绿 -> 黄
const Y_YELLOW_END := 610.0      # 515 ~ 610   纯黄
const Y_YELLOW_TO_RED := 710.0   # 610 ~ 710   黄 -> 红

# 箭头底色（ForwardBottomColor）
@export var base_color: Color = Color(1.0, 1.0, 1.0, 0.117647)
@export_range(0.0, 1.0) var base_pressed_alpha: float = 1.0

# ---------------- 以下一般不用改 ----------------

@onready var glow_color: ColorRect = $ForwardColor
@onready var bottom_color: ColorRect = $ForwardBottomColor

var _glow_material: ShaderMaterial = null
var _base_material: ShaderMaterial = null
var _base_idle_alpha: float = 0.0

# 记录所有正在触屏的手指及其当前位置（视口坐标）
var active_touches: Dictionary = {}

# 电脑鼠标测试状态
var mouse_pressed: bool = false
var mouse_position: Vector2 = Vector2.ZERO

var connection_node: Node = null
var forward_active: bool = false
var forward_send_timer: float = 0.0


func _ready() -> void:
	connection_node = get_tree().root.find_child("Connection",true,	false)
	_glow_material = glow_color.material as ShaderMaterial
	_base_material = bottom_color.material as ShaderMaterial

	_apply_style()

	glow_color.visible = false

	_update_glow_size()
	glow_color.resized.connect(_update_glow_size)


# 把上面那些变量推给节点与 shader（遮罩也在这里接上）
func _apply_style() -> void:
	bottom_color.color = base_color
	_base_idle_alpha = base_color.a

	if mask_texture != null:
		if _base_material != null:
			_base_material.set_shader_parameter("mask_texture", mask_texture)

		if _glow_material != null:
			_glow_material.set_shader_parameter("mask_texture", mask_texture)

	if _glow_material == null:
		return

	_glow_material.set_shader_parameter("circle_size", circle_size)
	_glow_material.set_shader_parameter("gradient_start", gradient_start)


func _process(delta: float) -> void:
	if not forward_active:
		forward_send_timer = 0.0
		return

	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	forward_send_timer += delta

	if forward_send_timer < FORWARD_SEND_INTERVAL:
		return

	forward_send_timer = 0.0

	connection_node.call(
		"send_action",
		"plane",
		{
			"command": "forward",
			"distance": FORWARD_STEP_DISTANCE * maxf(
				0.0,
				Options.get_float("plane/plane_speed")
			)
		}
	)
	

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return

	# 手机触屏：记录按下与松开
	if event is InputEventScreenTouch:
		if event.pressed:
			active_touches[event.index] = event.position
		else:
			active_touches.erase(event.index)

		_update_feedback()

	# 手机触屏：持续更新滑动位置
	elif event is InputEventScreenDrag:
		if active_touches.has(event.index):
			active_touches[event.index] = event.position
			_update_feedback()

	# 电脑鼠标：按下时开始追踪
	elif event is InputEventMouseButton:
		if event.button_index != MOUSE_BUTTON_LEFT:
			return

		mouse_pressed = event.pressed
		mouse_position = event.position
		_update_feedback()

	# 电脑鼠标：按住并滑动
	elif event is InputEventMouseMotion:
		mouse_position = event.position
		_update_feedback()


func _update_feedback() -> void:
	var active_position := Vector2.ZERO
	var is_inside := false

	# 只要任意一根手指位于区域内，就触发反馈
	for touch_position in active_touches.values():
		if _is_inside(touch_position):
			active_position = touch_position
			is_inside = true
			break

	# 鼠标测试
	if not is_inside and mouse_pressed and _is_inside(mouse_position):
		active_position = mouse_position
		is_inside = true
		
	forward_active = is_inside

	# 箭头底色：按下 → 变实心
	bottom_color.color.a = (
		base_pressed_alpha if is_inside else _base_idle_alpha
	)

	# 光晕圆：只有手指落在区域内时才出现
	glow_color.visible = is_inside

	if not is_inside or _glow_material == null:
		return

	# 手指在本区域内的局部坐标
	# （Control 没有 to_local()，且这里没有旋转/缩放，
	#   直接减去 global_position 与 _is_inside() 用的坐标系一致）
	var local_position: Vector2 = active_position - global_position

	# 圆心：x 固定为区域水平中心，y 取手指的局部 y
	_glow_material.set_shader_parameter(
		"circle_center",
		Vector2(glow_color.size.x * 0.5, local_position.y)
	)

	# 颜色：以本区域「底边」为 y = 0、向上为正，按手指高度取色
	_glow_material.set_shader_parameter(
		"circle_color",
		_color_for_y(size.y - local_position.y)
	)


# 以本区域底边为 y = 0（向上为正），按手指高度返回圆的颜色：
#   0    ~ 350   纯绿          (0, 1, 0)
#   350  ~ 515   绿 -> 黄      ( (y-350)/165 , 1 , 0 )
#   515  ~ 610   纯黄          (1, 1, 0)
#   610  ~ 710   黄 -> 红      ( 1 , 1-(y-610)/100 , 0 )
#   710 以上    纯红          (1, 0, 0)
func _color_for_y(y_from_bottom: float) -> Color:
	var color: Color

	if y_from_bottom <= Y_GREEN_END:
		color = COLOR_GREEN
	elif y_from_bottom <= Y_GREEN_TO_YELLOW:
		color = COLOR_GREEN.lerp(
			COLOR_YELLOW,
			(y_from_bottom - Y_GREEN_END)
			/ (Y_GREEN_TO_YELLOW - Y_GREEN_END)
		)
	elif y_from_bottom <= Y_YELLOW_END:
		color = COLOR_YELLOW
	elif y_from_bottom <= Y_YELLOW_TO_RED:
		color = COLOR_YELLOW.lerp(
			COLOR_RED,
			(y_from_bottom - Y_YELLOW_END)
			/ (Y_YELLOW_TO_RED - Y_YELLOW_END)
		)
	else:
		color = COLOR_RED

	color.a = circle_alpha

	return color


# 节点尺寸变化时同步给 shader（UV → 像素换算要用）
func _update_glow_size() -> void:
	if _glow_material == null:
		return

	_glow_material.set_shader_parameter(
		"node_size",
		glow_color.size
	)


func _is_inside(point: Vector2) -> bool:
	return get_global_rect().has_point(point)
