extends Node
# ============================================================
# options.gd —— 全局「用户选项」集中管理（Autoload 名：Options）
#
# 定位：
#   只放「用户可以在 App 设置里修改、并且需要持久化」的选项。
#   算法/布局类的只读常量（例如光流参数、NoticeBar 尺寸）不放这里，
#   它们留在各自脚本里，本文件不掺和。
#
# 新增一个设置项只需两步：
#   1. 在下面的 DEFAULTS 里加一行：
#          "<section>/<name>": <默认值>,
#   2. 设置界面调用：
#          Options.set_value("section/name", value)   写入
#          Options.get_value("section/name")          读取
#      想实时响应变化，就连接 Options.changed 信号。
#      写入会自动落盘到 user://blecaco_settings.cfg，无需手动 save()。
#
# 命名约定：key 一律用 "section/name"，与 .cfg 的分区一一对应。
# ============================================================

## 任意选项发生变化时发出。a_key 形如 "mode/scene_path"。
signal changed(a_key: String, a_value: Variant)

# ------------------------------------------------------------
# 持久化文件
# ------------------------------------------------------------
const CONFIG_FILE := "user://blecaco_settings.cfg"

# ------------------------------------------------------------
# 模式场景清单 —— 全工程唯一来源。
# main.gd / setting.gd / mode_select.gd 一律从这里取，
# 不要再各自抄一份路径列表。
# ------------------------------------------------------------
const MODE_SCENES := {
	"FreeCover": "res://scenes/modes/free_mode.tscn",
	"PlaneCover": "res://scenes/modes/plane_mode.tscn",
	"CarCover": "res://scenes/modes/car_mode.tscn",
	"GameCover": "res://scenes/modes/game_mode.tscn",
	"CameraCover": "res://scenes/modes/camera_mode.tscn",
	"DroneCover": "res://scenes/modes/drone_mode.tscn"
}

const DEFAULT_MODE_SCENE := MODE_SCENES["FreeCover"]

# ------------------------------------------------------------
# 所有「可持久化选项」的默认值都登记在这里。
# key = "section/name"，与 .cfg 的分区一一对应。
# ------------------------------------------------------------
const DEFAULTS := {
	"mode/scene_path": DEFAULT_MODE_SCENE,
	"move_speed": 1.0,
	# 例外项：这不是「用户选项」，而是 Blender 运行时同步过来的状态
	# （插件在客户端接入/帧率变化时推送 setting/output_fps，见 main.gd）。
	# 放在这里只为让各模式有统一的读取入口，不进设置界面、不参与持久化。
	"blender/output_fps": 60.0,
	# 姿态平滑强度 0.0 ~ 1.0（0 = 完全关闭，1 = 最强）。
	# 由 getrotation.gd 的 One Euro Filter 使用，作用于所有模式。
	# 注意它同时影响「手机看到的预览」与「录制出的动画」——
	# 因为这两者本来就是同一条数据流渲出来的，这是想要的效果。
	# 设置页做好后挂一个滑条即可。
	"record/smoothness": 0.5
}

# 运行期的实际取值（_load 时以 DEFAULTS 为底，再用存档覆盖）
var _values: Dictionary = {}


func _ready() -> void:
	_load()


# ============================================================
# 通用读写 API
# ============================================================

## 读取选项。未登记且没有存档时返回 a_fallback。
func get_value(a_key: String, a_fallback: Variant = null) -> Variant:
	if _values.has(a_key):
		return _values[a_key]

	if DEFAULTS.has(a_key):
		return DEFAULTS[a_key]

	return a_fallback


## 写入选项。默认立刻落盘并广播 changed。
## 高频写入（例如滑条拖动过程中）请传 a_save_now = false，
## 在拖动结束 / 页面关闭时再调用 Options.save()。
func set_value(
	a_key: String,
	a_value: Variant,
	a_save_now: bool = true
) -> void:
	if _values.get(a_key) == a_value:
		return

	_values[a_key] = a_value

	if a_save_now:
		save()

	changed.emit(a_key, a_value)


func get_bool(a_key: String) -> bool:
	return bool(get_value(a_key))


func get_int(a_key: String) -> int:
	return int(get_value(a_key))


func get_float(a_key: String) -> float:
	return float(get_value(a_key))


func get_string(a_key: String) -> String:
	return str(get_value(a_key))


## 把所有选项恢复为默认值并落盘。
func reset_to_defaults() -> void:
	_values = DEFAULTS.duplicate(true)
	save()

	for a_key in _values.keys():
		changed.emit(a_key, _values[a_key])


# ============================================================
# 模式场景便捷接口（单一来源 = MODE_SCENES / DEFAULTS）
# ============================================================

## 取当前模式场景路径；存档非法时回退到 DEFAULT_MODE_SCENE。
func get_mode_scene_path() -> String:
	var scene_path := get_string("mode/scene_path")

	if not is_valid_mode_scene(scene_path):
		return DEFAULT_MODE_SCENE

	return scene_path


## 设置模式场景路径；非法路径会被拒绝并给出警告。
func set_mode_scene_path(a_scene_path: String) -> void:
	if not is_valid_mode_scene(a_scene_path):
		push_warning("[Options] 无效的模式场景：" + a_scene_path)
		return

	set_value("mode/scene_path", a_scene_path)


## 路径必须出现在 MODE_SCENES 清单里，且资源真实存在。
func is_valid_mode_scene(a_scene_path: String) -> bool:
	return (
		MODE_SCENES.values().has(a_scene_path)
		and ResourceLoader.exists(a_scene_path)
	)


# ============================================================
# 存档读写（外部一般不需要直接调用）
# ============================================================

func _load() -> void:
	_values = DEFAULTS.duplicate(true)

	var config := ConfigFile.new()
	var error := config.load(CONFIG_FILE)

	if error != OK:
		if error != ERR_FILE_NOT_FOUND:
			push_warning("[Options] 读取选项失败：" + str(error))

		return

	for a_key in DEFAULTS.keys():
		var parts: PackedStringArray = str(a_key).split("/", true, 1)

		if parts.size() != 2:
			push_warning("[Options] 非法 key（应为 section/name）：" + a_key)
			continue

		_values[a_key] = config.get_value(
			parts[0],
			parts[1],
			DEFAULTS[a_key]
		)


func save() -> void:
	var config := ConfigFile.new()

	for a_key in _values.keys():
		var parts: PackedStringArray = str(a_key).split("/", true, 1)

		if parts.size() != 2:
			continue

		config.set_value(parts[0], parts[1], _values[a_key])

	var error := config.save(CONFIG_FILE)

	if error != OK:
		push_error("[Options] 保存选项失败：" + str(error))
		return

	print("[Options] 选项已保存：", CONFIG_FILE)
