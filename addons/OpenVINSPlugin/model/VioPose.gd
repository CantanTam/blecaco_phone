class_name VioPose
extends RefCounted
# OpenVINS 输出的相机位姿（含真实尺度，单位为米）。
#
# 数据来源：OpenVINSBridge.getPose() 返回的长度 7 的 double[]：
#   [px, py, pz, qw, qx, qy, qz]
# 注意四元数顺序是 w 在前，与 Godot 的 Quaternion(x,y,z,w) 不同，构造时要换序。

const POSE_ARRAY_SIZE: int = 7

## 位置（米），相对 VIO 初始化时刻
var position: Vector3 = Vector3.ZERO

## 姿态（Godot 顺序 x, y, z, w）
var orientation: Quaternion = Quaternion.IDENTITY


func _init(
	a_position: Vector3 = Vector3.ZERO,
	a_orientation: Quaternion = Quaternion.IDENTITY
) -> void:
	position = a_position
	orientation = a_orientation


## 从 Java 返回的 double[7] 构造；数据不合法时返回 null。
static func from_java_pose(a_values) -> VioPose:
	if a_values == null:
		return null

	var values: PackedFloat64Array

	if typeof(a_values) == TYPE_PACKED_FLOAT64_ARRAY:
		values = a_values
	elif typeof(a_values) == TYPE_ARRAY:
		for item in a_values:
			values.append(float(item))
	else:
		return null

	if values.size() < POSE_ARRAY_SIZE:
		return null

	return VioPose.new(
		Vector3(values[0], values[1], values[2]),
		Quaternion(values[4], values[5], values[6], values[3]).normalized()
	)


func get_position() -> Vector3:
	return position


func get_orientation() -> Quaternion:
	return orientation


func _to_string() -> String:
	return "VioPose(pos=%s, quat=%s)" % [position, orientation]
