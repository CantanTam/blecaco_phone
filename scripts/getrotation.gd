extends RefCounted

const ORIENTATION_PLUGIN_NAME := "GodotAndroidPluginTemplate"

var _orientation_plugin: Object = null

# 手动校准时保存的参考姿态
var _reference_orientation: Quaternion = Quaternion.IDENTITY
var _is_calibrated: bool = false


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


# 手动校准：将调用时的手机姿态设为参考姿态。
# 进入 Free Mode 时不会自动调用。
func calibrate() -> bool:
	if not has_orientation_data():
		return false

	_reference_orientation = _read_android_orientation()
	_is_calibrated = true

	return true


func is_calibrated() -> bool:
	return _is_calibrated


# 取消校准，恢复直接读取传感器姿态。
func clear_calibration() -> void:
	_is_calibrated = false


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

	return _convert_phone_to_camera(
		output_orientation
	)
