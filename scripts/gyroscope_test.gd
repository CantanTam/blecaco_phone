extends Node

const LOG_INTERVAL: float = 1.0

var log_timer: float = 0.0

# 累积手机旋转，初始状态为单位四元数
var orientation: Quaternion = Quaternion.IDENTITY


func _ready() -> void:
	print("Gyroscope quaternion test started")


func _process(delta: float) -> void:
	# 获取手机三个轴的角速度，单位 rad/s
	var gyro: Vector3 = Input.get_gyroscope()

	# 将角速度转换为这一帧的旋转
	var angular_speed: float = gyro.length()

	if angular_speed > 0.000001:
		var axis: Vector3 = gyro / angular_speed
		var angle: float = angular_speed * delta

		var delta_rotation: Quaternion = Quaternion(axis, angle)

		# 将本帧旋转累积到当前姿态
		orientation = (orientation * delta_rotation).normalized()

	# 每秒输出一次
	log_timer += delta

	if log_timer < LOG_INTERVAL:
		return

	log_timer = 0.0

	print(
		"Quaternion (x,y,z,w): ",
		"qx=", snappedf(orientation.x, 0.001),
		" qy=", snappedf(orientation.y, 0.001),
		" qz=", snappedf(orientation.z, 0.001),
		" qw=", snappedf(orientation.w, 0.001)
	)
