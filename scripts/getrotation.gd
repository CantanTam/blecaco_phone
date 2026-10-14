extends RefCounted

const ORIENTATION_PLUGIN_NAME := "GodotAndroidPluginTemplate"

# ============================================================
# 姿态平滑：One Euro Filter，直接作用在四元数上
# ============================================================
# 强度来自 Options 的 "record/smoothness"（0.0 ~ 1.0）：
#   0.0 = 完全旁路，输出与改造前逐位一致（用来 A/B 对比）
#   1.0 = 最强
#
# 为什么不把 4 个分量分别做线性平均：
#   四元数住在单位球面 S³ 上，正确的「平均」是沿测地线的 slerp；
#   分量 lerp 会让角速度两头快中间慢（看起来一顿一顿），
#   而且遇到 q / -q（同一旋转的两种表示）会直接算废。
#
# 为什么用 One Euro 而不是固定系数：
#   固定系数只有两种下场 —— 滤得狠则延迟大、滤得轻则照样抖。
#   One Euro 让截止频率随角速度自适应：
#     慢 → 强滤（静止时不抖）    快 → 几乎不滤（不迟到、不削峰）
const SMOOTH_MIN_CUTOFF_HZ := 0.5      # smoothness = 1 时的最低截止频率
const SMOOTH_MAX_CUTOFF_HZ := 30.0     # smoothness → 0 时的最高截止频率（约等于不滤）
const SMOOTH_BETA := 0.12              # 速度自适应系数（角速度单位：度/秒）
const SMOOTH_DERIVATIVE_CUTOFF_HZ := 1.0   # 角速度本身的低通，压住速度估计的毛刺
const SMOOTH_MAX_DT := 0.1             # dt 上限：App 从后台回来时别一口气补太多

# 速度死区（度/秒）：低于这个速度视为「静止」。
# 必须有它：静止时 ±0.6° 的传感器噪声在 16.7ms 内相当于 36°/s 的"瞬时角速度"，
# 会被 One Euro 当成快速运动从而削弱滤波 —— 结果就是静止时还是抖。
# 这里用「减去死区」而不是硬阈值，避免响应出现台阶。
const SMOOTH_SPEED_DEADBAND := 10.0

var _orientation_plugin: Object = null

# 手动校准时保存的参考姿态
var _reference_orientation: Quaternion = Quaternion.IDENTITY
var _is_calibrated: bool = false

# ---- 平滑器状态 ----
var _smoothed_orientation: Quaternion = Quaternion.IDENTITY
var _previous_input: Quaternion = Quaternion.IDENTITY
var _smoothed_speed: float = 0.0        # 滤波后的角速度（度/秒）
var _smooth_ready: bool = false
var _smooth_last_usec: int = 0


func _get_orientation_plugin() -> Object:
	if _orientation_plugin != null:
		return _orientation_plugin

	if Engine.has_singleton(ORIENTATION_PLUGIN_NAME):
		_orientation_plugin = Engine.get_singleton(
			ORIENTATION_PLUGIN_NAME
		)

	return _orientation_plugin


func is_available() -> bool:
	return _get_orientation_plugin() != null


func has_orientation_data() -> bool:
	var plugin = _get_orientation_plugin()

	if plugin == null:
		return false

	return plugin.hasOrientationData()


# 读取 Android 当前姿态。
# 插件返回顺序：X、Y、Z、W。
func _read_android_orientation() -> Quaternion:
	var plugin = _get_orientation_plugin()
	var values = plugin.getRotationQuaternion()

	return Quaternion(
		float(values[0]),
		float(values[1]),
		float(values[2]),
		float(values[3])
	).normalized()


# 根据确定的六条轴向关系转换四元数。
#
# Camera -X -> Phone +Y
# Camera +X -> Phone -Y
# Camera +Y -> Phone +X
# Camera -Y -> Phone -X
# Camera +Z -> Phone +Z
# Camera -Z -> Phone -Z
#
# 因此，Phone 坐标系下的旋转轴分量
# 转换到 Camera 坐标系时：
# X = -Phone Y
# Y =  Phone X
# Z =  Phone Z
# W 保持不变
func _convert_phone_to_camera(
	phone_q: Quaternion
) -> Quaternion:
	return Quaternion(
		-phone_q.y,
		phone_q.x,
		phone_q.z,
		phone_q.w
	).normalized()


# ============================================================
# 平滑实现
# ============================================================

# 当前平滑强度：0 = 关闭，1 = 最强
func _smoothness() -> float:
	return clampf(Options.get_float("record/smoothness"), 0.0, 1.0)


# 把强度映射成 One Euro 的最低截止频率。
# 用指数插值而非线性：截止频率是对数尺度，
# 这样滑条从 0 → 1 的「手感增量」才是均匀的。
func _base_cutoff(smoothness: float) -> float:
	return SMOOTH_MAX_CUTOFF_HZ * pow(
		SMOOTH_MIN_CUTOFF_HZ / SMOOTH_MAX_CUTOFF_HZ,
		smoothness
	)


# 一阶低通系数：alpha = 1 / (1 + tau/dt)，tau = 1/(2π·cutoff)
func _lowpass_alpha(cutoff_hz: float, dt: float) -> float:
	if cutoff_hz <= 0.0 or dt <= 0.0:
		return 1.0

	var tau := 1.0 / (TAU * cutoff_hz)

	return clampf(1.0 / (1.0 + tau / dt), 0.0, 1.0)


# 清掉平滑器状态（校准 / 重新开启平滑时调用，免得旧状态拖尾）
func _reset_smoothing() -> void:
	_smoothed_orientation = Quaternion.IDENTITY
	_previous_input = Quaternion.IDENTITY
	_smoothed_speed = 0.0
	_smooth_ready = false
	_smooth_last_usec = 0


# One Euro Filter：在四元数上做「速度自适应 slerp 低通」
func _smooth_orientation(target: Quaternion) -> Quaternion:
	var now_usec := Time.get_ticks_usec()
	var dt := 0.0

	if _smooth_last_usec > 0:
		dt = clampf(
			float(now_usec - _smooth_last_usec) / 1000000.0,
			0.0,
			SMOOTH_MAX_DT
		)

	_smooth_last_usec = now_usec

	# 首帧 / 时间没走：直接采用，不做平滑
	if not _smooth_ready or dt <= 0.0:
		_smoothed_orientation = target
		_previous_input = target
		_smoothed_speed = 0.0
		_smooth_ready = true
		return target

	# 符号对齐：q 与 -q 表示同一个旋转，不做这一步角度会算成接近 2π
	var aligned := target

	if _previous_input.dot(aligned) < 0.0:
		aligned = -aligned

	# 角速度用「上一帧的原始输入」估计 —— 这是 One Euro 的定义。
	# 不能拿自己的滤波输出算：那会低估速度 → 截止频率上不去 → 越滤越迟滞。
	var dot := clampf(_previous_input.dot(aligned), -1.0, 1.0)
	var speed := rad_to_deg(2.0 * acos(dot)) / dt
	_previous_input = aligned

	# 速度本身也低通一次（导数滤波），压住估计毛刺
	_smoothed_speed = lerpf(
		_smoothed_speed,
		speed,
		_lowpass_alpha(SMOOTH_DERIVATIVE_CUTOFF_HZ, dt)
	)

	# 截止频率随速度自适应，再据此取 slerp 系数。
	# 先扣掉死区，免得静止时的噪声把截止频率顶上去。
	var effective_speed := maxf(
		_smoothed_speed - SMOOTH_SPEED_DEADBAND,
		0.0
	)
	var cutoff := _base_cutoff(_smoothness()) + SMOOTH_BETA * effective_speed
	var alpha := _lowpass_alpha(cutoff, dt)

	_smoothed_orientation = (
		_smoothed_orientation.slerp(aligned, alpha).normalized()
	)

	return _smoothed_orientation


# 手动校准：将调用时的手机姿态设为参考姿态。
# 进入 Free Mode 时不会自动调用。
func calibrate() -> bool:
	if not has_orientation_data():
		return false

	_reference_orientation = _read_android_orientation()
	_is_calibrated = true
	_reset_smoothing()

	return true


func is_calibrated() -> bool:
	return _is_calibrated


# 取消校准，恢复直接读取传感器姿态。
func clear_calibration() -> void:
	_is_calibrated = false
	_reset_smoothing()


# 获取转换到 Blender Camera 坐标系的四元数。
func get_rotation_quaternion() -> Quaternion:
	if not has_orientation_data():
		return Quaternion.IDENTITY

	var current_orientation: Quaternion = (
		_read_android_orientation()
	)

	var output_orientation: Quaternion = current_orientation

	if _is_calibrated:
		output_orientation = (
			_reference_orientation.inverse()
			* current_orientation
		).normalized()

	output_orientation = _convert_phone_to_camera(
		output_orientation
	)

	# 平滑（smoothness = 0 时完全旁路，输出与改造前一致）
	if _smoothness() > 0.0:
		return _smooth_orientation(output_orientation)

	_reset_smoothing()

	return output_orientation
