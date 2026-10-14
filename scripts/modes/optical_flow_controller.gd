extends Node

@onready var camera: NativeCamera = $NativeCamera

# ============================================================
# 光流运动估计：3 层金字塔 + 角点块匹配 + 鲁棒相似变换
# ============================================================
#
# 对外输出约定（与 Blender 端 blecaco/free_action.py 一一对应，
# 不可更改）：
#   x      —— 图像特征水平位移（像素/帧），已剔除旋转与缩放
#   y      —— 图像特征垂直位移（像素/帧），已剔除旋转与缩放
#   radial —— 画面整体扩张量（像素/帧），>0 前进、<0 后退
#
# 旧实现为什么「效果非常差」（本次逐条修复）：
#   1. 搜索半径只有 4px。正常持机走动每帧位移常常 5~20px，
#      一旦超出就几乎必然匹配失败 → 输出长期为 0 或随机跳变。
#      → 改为 3 层金字塔由粗到细匹配（等效 ±18px）＋上一帧运动预测。
#   2. 用「块内 max-min 对比度」筛特征，只能排除纯色区域，排不掉
#      只能测出单方向位移的「边缘」（孔径问题），大量单向约束
#      会把中位数整体拉偏。
#      → 改为在最粗层用 Shi-Tomasi 最小特征值挑角点，并做网格均匀化。
#   3. 取整数位移的中位数 → 亚像素抖动（±0.5px 量化噪声）。
#      → 改为 SAD 曲面抛物线拟合，亚像素精度约 0.1px。
#   4. 没有误匹配剔除：只要有 8 个块被接受就出结果。
#      → 改为双向一致性校验 + 匹配代价门限 + 内点数门限。
#   5. 分别对 dx、dy 取中位数，丢掉了两者相关性，
#      并且完全没有区分「平移 / 旋转 / 前后」。
#      → 改为 RANSAC + 最小二乘拟合 4 自由度相似变换
#           u = tx + p*(x-cx) - q*(y-cy)
#           v = ty + q*(x-cx) + p*(y-cy)
#        · (tx, ty) = 剔除旋转/缩放后的真实平移 → x / y
#        · p        = 膨胀率（缩放），即前进/后退 → radial
#        · q        = 滚转（旋转）
#   6. 旧版「径向运动」是以画面中心做投影，横向平移同样会产生
#      很大的径向分量 → 前进/后退通道完全不可用。
#      → 现在前进/后退直接来自相似变换的缩放项 p，与横向平移天然解耦。
#
# 仍存在的固有局限（纯视觉无法解决，需要 IMU）：
#   手机俯仰/偏航造成的整幅匀流与真实横向平移在数学上不可区分，
#   只能用陀螺仪/姿态（scripts/getrotation.gd）做前馈补偿。
#   本文件保持纯视觉、自包含，IMU 融合留作后续独立步骤。
# ============================================================

# ---------------- 金字塔 ----------------
# L0 = 原始（320x240），L1 = 1/2，L2 = 1/4
const PYRAMID_LEVELS: int = 3
const COARSE_LEVEL: int = 2
const DETECT_LEVEL: int = 2

# ---------------- 块匹配 ----------------
# 索引即层级：0 = L0，1 = L1，2 = L2
const BLOCK_RADII := [2, 1, 1]
const SEARCH_RADII := [2, 2, 3]
# 最粗层先用大步长扫一遍再精化，可省掉约 40% 的匹配代价
const COARSE_STEP_LEVEL2: int = 2

# ---------------- 特征点 ----------------
const MAX_FEATURES: int = 36
const FEATURE_CELL: int = 8          # 检测层上每个网格只保留一个最强角点
const SHI_TOMASI_MIN_RATIO: float = 0.02
const FEATURE_MARGIN: int = 5        # 检测层的边界余量

# ---------------- 校验 ----------------
const MAX_MEAN_ABS_DIFF: float = 40.0  # 单点接受门限（每像素平均绝对差）
const FB_MAX_ERROR: float = 1.0        # 双向一致性误差（L0 像素）
const RANSAC_ITERATIONS: int = 48
const RANSAC_INLIER_DIST: float = 1.2
const RANSAC_MIN_BASELINE: float = 16.0
const MIN_INLIERS: int = 8
const MAX_FLOW_PX: float = 60.0        # 单帧位移上限，超出判为异常

# ---------------- 时间滤波 ----------------
const FLOW_SMOOTHING_ALPHA: float = 0.35
const FLOW_DEADZONE_PX: float = 0.3
const LOST_DECAY: float = 0.5

# ---------------- 调试 ----------------
const DEBUG_FLOW_LOG: bool = false
const DEBUG_FLOW_INTERVAL: int = 30

# ============================================================
# 光流后台工作线程
# ============================================================

var _flow_thread: Thread = Thread.new()
var _flow_mutex: Mutex = Mutex.new()
var _flow_semaphore: Semaphore = Semaphore.new()

var _flow_thread_running: bool = false

# 最新待处理的摄像头帧
var _latest_frame: PackedByteArray = PackedByteArray()
var _latest_width: int = 0
var _latest_height: int = 0

# 是否已经通知工作线程有新帧
var _flow_wakeup_pending: bool = false

# 由工作线程维护的参考帧
var _worker_previous_buffer: PackedByteArray = PackedByteArray()
var _worker_previous_width: int = 0
var _worker_previous_height: int = 0

# 工作线程计算的最新结果
var _flow_result: Vector2 = Vector2.ZERO
var _flow_radial_result: float = 0.0
var _flow_match_result: int = 0
var _flow_result_valid: bool = false
var _flow_result_ready: bool = false

# 光流平滑状态
var _smoothed_motion: Vector2 = Vector2.ZERO
var _smoothed_radial_motion: float = 0.0
var _has_smoothed_motion: bool = false

# 工作线程内部的上一帧模型（仅工作线程访问，无需加锁）
var _has_model: bool = false
var _model_tx: float = 0.0
var _model_ty: float = 0.0
var _model_p: float = 0.0
var _model_q: float = 0.0

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _worker_frame_count: int = 0

# 工作线程缓存：上一帧的金字塔。
# 因为 work_previous = 上一轮的 current，所以每次只需重建一套金字塔。
var _worker_prev_pyramid: Array[PackedByteArray] = []
var _worker_prev_pyramid_ready: bool = false

# 工作线程统计量（调试用）
var last_match_count: int = 0
var last_radial_motion: float = 0.0
var last_rotation: float = 0.0
var last_expansion: float = 0.0

var connection_node: Node = null


func _ready() -> void:
	# 查找现有的 Connection 节点
	connection_node = get_tree().root.find_child(
		"Connection",
		true,
		false
	)

	if connection_node == null:
		push_error(
			"[OpticalFlow] Connection 节点不存在"
		)
	elif not connection_node.has_method("send_action"):
		push_error(
			"[OpticalFlow] Connection.send_action() 不存在"
		)
		connection_node = null

	_rng.randomize()

	# 配置 NativeCamera
	camera.frame_width = 320
	camera.frame_height = 240
	camera.frames_to_skip = 0
	camera.is_grayscale = true
	camera.scale_width = 320
	camera.scale_height = 240
	camera.auto_upright = true

	camera.frame_available.connect(_on_frame_available)
	camera.camera_permission_granted.connect(_start_camera)
	camera.camera_permission_denied.connect(
		_on_camera_permission_denied
	)

	# 启动光流工作线程
	_flow_thread_running = true

	var thread_error: Error = _flow_thread.start(
		_flow_worker
	)

	if thread_error != OK:
		_flow_thread_running = false
		push_error(
			"[OpticalFlow] 无法启动后台线程"
		)
		return

	if camera.has_camera_permission():
		_start_camera()
	else:
		camera.request_camera_permission()


func _start_camera() -> void:
	var cameras := camera.get_all_cameras()

	if cameras.is_empty():
		push_error("[OpticalFlow] No camera found.")
		return

	var selected_camera: CameraInfo = cameras[0]

	for cam in cameras:
		if not cam.is_front_facing():
			selected_camera = cam
			break

	var request := camera.create_feed_request()
	request.set_camera_id(selected_camera.get_camera_id())
	request.set_width(640)
	request.set_height(480)
	request.set_scale_width(320)
	request.set_scale_height(240)
	request.set_frames_to_skip(0)
	request.set_grayscale(true)
	request.set_auto_upright(true)

	camera.start(request)


func _on_camera_permission_denied() -> void:
	push_error("[OpticalFlow] Camera permission denied")


func _on_frame_available(info: FrameInfo) -> void:
	if not info.is_grayscale():
		return

	var current_buffer: PackedByteArray = info.get_buffer()
	var width: int = info.get_width()
	var height: int = info.get_height()

	if current_buffer.size() != width * height:
		return

	# 在主线程复制最新图像。
	# 后台线程不直接访问 NativeCamera。
	var frame_copy: PackedByteArray = current_buffer.duplicate()
	var should_wake_worker: bool = false

	_flow_mutex.lock()

	if not _flow_thread_running:
		_flow_mutex.unlock()
		return

	# 只保留最新图像，不积压旧帧。
	_latest_frame = frame_copy
	_latest_width = width
	_latest_height = height

	# 已经有唤醒信号时，不重复提交信号。
	if not _flow_wakeup_pending:
		_flow_wakeup_pending = true
		should_wake_worker = true

	_flow_mutex.unlock()

	if should_wake_worker:
		_flow_semaphore.post()


func _process(_delta: float) -> void:
	var has_result: bool = false
	var valid: bool = false
	var motion: Vector2 = Vector2.ZERO
	var radial: float = 0.0
	var inliers: int = 0

	# 从后台线程取得最新光流结果
	_flow_mutex.lock()

	if _flow_result_ready:
		motion = _flow_result
		radial = _flow_radial_result
		inliers = _flow_match_result
		valid = _flow_result_valid
		_flow_result_ready = false
		has_result = true

	_flow_mutex.unlock()

	if not has_result:
		return

	# 跟踪失败（内点不足 / 场景无纹理）：向 0 衰减，
	# 避免把最后一段错误速度一直发出去，同时让相机平滑停住。
	if not valid:
		_smoothed_motion *= LOST_DECAY
		_smoothed_radial_motion *= LOST_DECAY
		_apply_deadzone(_smoothed_motion, _smoothed_radial_motion)
		_send_translation(
			_smoothed_motion,
			_smoothed_radial_motion
		)
		return

	if not _has_smoothed_motion:
		# 第一次拿到结果时直接采用，避免启动时缓慢爬升
		_smoothed_motion = motion
		_smoothed_radial_motion = radial
		_has_smoothed_motion = true
	else:
		# 内点越多，说明本帧越可信，允许更快的跟随速度
		var quality: float = clampf(
			float(inliers) / float(maxi(MIN_INLIERS, 1)),
			0.3,
			1.5
		)
		var alpha: float = clampf(
			FLOW_SMOOTHING_ALPHA * quality,
			0.08,
			0.6
		)
		_smoothed_motion = _smoothed_motion.lerp(
			motion,
			alpha
		)
		_smoothed_radial_motion = lerpf(
			_smoothed_radial_motion,
			radial,
			alpha
		)

	_apply_deadzone(
		_smoothed_motion,
		_smoothed_radial_motion
	)

	# 仍然在主线程向 Blender 发送数据
	_send_translation(
		_smoothed_motion,
		_smoothed_radial_motion
	)


# 死区：小于门限的残余抖动直接归零，静止时不发送噪声。
func _apply_deadzone(
	motion: Vector2,
	radial: float
) -> void:
	_smoothed_motion = motion
	_smoothed_radial_motion = radial

	if absf(_smoothed_motion.x) < FLOW_DEADZONE_PX:
		_smoothed_motion.x = 0.0

	if absf(_smoothed_motion.y) < FLOW_DEADZONE_PX:
		_smoothed_motion.y = 0.0

	if absf(_smoothed_radial_motion) < FLOW_DEADZONE_PX:
		_smoothed_radial_motion = 0.0


func _send_translation(motion: Vector2, radial: float) -> void:
	if connection_node == null:
		return

	if not is_instance_valid(connection_node):
		return

	if not connection_node.has_method("send_action"):
		return

	var translation_data: Dictionary = {
		"command": "translation",
		"x": motion.x,
		"y": motion.y,
		"radial": radial
	}

	connection_node.call(
		"send_action",
		"free",
		translation_data
	)


# ============================================================
# 后台光流工作线程
# ============================================================

func _flow_worker() -> void:
	while true:
		# 等待主线程提交新帧
		_flow_semaphore.wait()

		var frame: PackedByteArray
		var width: int
		var height: int

		# 取得最新帧，然后释放锁，让主线程继续运行
		_flow_mutex.lock()

		if not _flow_thread_running:
			_flow_mutex.unlock()
			break

		frame = _latest_frame
		width = _latest_width
		height = _latest_height

		_flow_wakeup_pending = false

		_flow_mutex.unlock()

		if frame.is_empty() or width <= 0 or height <= 0:
			continue

		# 首帧或图像尺寸发生变化时，只更新参考帧并复位运动模型
		if (
			_worker_previous_buffer.is_empty()
			or _worker_previous_width != width
			or _worker_previous_height != height
		):
			_worker_previous_buffer = frame
			_worker_previous_width = width
			_worker_previous_height = height
			_has_model = false
			_worker_prev_pyramid_ready = false
			continue

		# 在后台线程中进行光流计算
		var result: Dictionary = _estimate_motion(
			_worker_previous_buffer,
			frame,
			width,
			height,
			true
		)

		# 保留本次计算的参考帧
		_worker_previous_buffer = frame
		_worker_previous_width = width
		_worker_previous_height = height

		if result["valid"]:
			last_match_count = int(result["inliers"])
			last_radial_motion = float(result["radial"])
			last_rotation = float(result["rotation"])
			last_expansion = float(result["expansion"])
		else:
			last_match_count = 0

		_worker_frame_count += 1

		if DEBUG_FLOW_LOG and _worker_frame_count % DEBUG_FLOW_INTERVAL == 0:
			print(
				"[OpticalFlow] feats=", result["features"],
				" inliers=", result["inliers"],
				" fb_rej=", result["fb_rejected"],
				" motion=", result["motion"],
				" radial=", result["radial"],
				" rot=", snappedf(float(result["rotation"]), 0.0001),
				" exp=", snappedf(float(result["expansion"]), 0.0001),
				" rms=", snappedf(float(result["rms"]), 0.01)
			)

		# 将结果交给主线程
		_flow_mutex.lock()

		_flow_result = Vector2(result["motion"])
		_flow_radial_result = float(result["radial"])
		_flow_match_result = int(result["inliers"])
		_flow_result_valid = bool(result["valid"])
		_flow_result_ready = true

		_flow_mutex.unlock()


# ============================================================
# 单帧运动估计主流程
# ============================================================

func _estimate_motion(
	previous: PackedByteArray,
	current: PackedByteArray,
	width: int,
	height: int,
	reuse_previous_pyramid: bool = false
) -> Dictionary:
	if width < 32 or height < 32:
		return _invalid_result()

	var prev_pyr: Array[PackedByteArray]

	if reuse_previous_pyramid and _worker_prev_pyramid_ready:
		prev_pyr = _worker_prev_pyramid
	else:
		prev_pyr = _build_pyramid(previous, width, height)

	var curr_pyr: Array[PackedByteArray] = _build_pyramid(
		current,
		width,
		height
	)

	# 下一轮的 previous 就是本轮的 current，直接复用。
	_worker_prev_pyramid = curr_pyr
	_worker_prev_pyramid_ready = true

	var dims: Array[Vector2i] = _pyramid_dims(width, height)

	var detect_dims: Vector2i = dims[DETECT_LEVEL]
	var candidates: Array[Vector2] = _detect_features(
		prev_pyr[DETECT_LEVEL],
		detect_dims.x,
		detect_dims.y
	)

	if candidates.size() < MIN_INLIERS:
		return _invalid_result()

	var center := Vector2(width * 0.5, height * 0.5)
	var detect_scale := float(1 << DETECT_LEVEL)

	var l0_radius: int = int(BLOCK_RADII[0])
	var l0_block_area: float = float(
		(2 * l0_radius + 1) * (2 * l0_radius + 1)
	)

	var src: Array[Vector2] = []
	var flow: Array[Vector2] = []
	var fb_rejected: int = 0

	for candidate in candidates:
		var p0: Vector2 = candidate * detect_scale

		# 用上一帧模型预测本帧位移。
		# 预测越准，金字塔要覆盖的搜索范围就越小、越不容易跟丢。
		var predict := Vector2.ZERO
		if _has_model:
			predict = _predict_flow(p0, center)

		var disp: Vector2 = _track_l0(
			prev_pyr,
			curr_pyr,
			dims,
			p0,
			predict
		)

		# L0 匹配代价门限：无纹理区域 / 误匹配直接丢弃
		var cost := _sad(
			prev_pyr[0],
			curr_pyr[0],
			dims[0].x,
			roundi(p0.x),
			roundi(p0.y),
			roundi(disp.x),
			roundi(disp.y),
			l0_radius
		)

		if float(cost) / l0_block_area > MAX_MEAN_ABS_DIFF:
			continue

		# 双向一致性校验：倒过来再跟一次，往返误差必须很小
		var q0: Vector2 = p0 + disp
		var back: Vector2 = _match_at_level(
			curr_pyr[0],
			prev_pyr[0],
			dims[0].x,
			dims[0].y,
			q0,
			-disp,
			int(SEARCH_RADII[0]),
			l0_radius,
			1
		)

		if (disp + back).length() > FB_MAX_ERROR:
			fb_rejected += 1
			continue

		src.append(p0)
		flow.append(disp)

	if src.size() < MIN_INLIERS:
		return _invalid_result()

	var model: Dictionary = _fit_similarity(src, flow, center)

	if not model["valid"]:
		return _invalid_result()

	var motion := Vector2(float(model["tx"]), float(model["ty"]))
	var expansion := float(model["p_exp"])

	# 异常帧拒收：位移或膨胀量远超物理合理范围
	if motion.length() > MAX_FLOW_PX:
		return _invalid_result()

	if absf(expansion) * center.x > MAX_FLOW_PX:
		return _invalid_result()

	# 把「膨胀率」折算成与旧版一致的像素/帧量纲：
	# 半径 R 处的径向位移 ≈ p * R，因此取特征点的平均半径。
	var radius_sum := 0.0
	for point in src:
		radius_sum += (point - center).length()

	var mean_radius := radius_sum / float(src.size())
	var radial := expansion * mean_radius

	_has_model = true
	_model_tx = motion.x
	_model_ty = motion.y
	_model_p = expansion
	_model_q = float(model["q_rot"])

	return {
		"valid": true,
		"motion": motion,
		"radial": radial,
		"inliers": int(model["inliers"]),
		"features": src.size(),
		"fb_rejected": fb_rejected,
		"rotation": float(model["q_rot"]),
		"expansion": expansion,
		"rms": float(model["rms"])
	}


func _invalid_result() -> Dictionary:
	return {
		"valid": false,
		"motion": Vector2.ZERO,
		"radial": 0.0,
		"inliers": 0,
		"features": 0,
		"fb_rejected": 0,
		"rotation": 0.0,
		"expansion": 0.0,
		"rms": 0.0
	}


# ============================================================
# 图像金字塔
# ============================================================

func _pyramid_dims(width: int, height: int) -> Array[Vector2i]:
	var dims: Array[Vector2i] = []
	var w := width
	var h := height

	for _level in PYRAMID_LEVELS:
		dims.append(Vector2i(w, h))
		w = maxi(1, w >> 1)
		h = maxi(1, h >> 1)

	return dims


# 2x2 均值下采样构成金字塔。PackedByteArray 只读共享，不做额外拷贝。
func _build_pyramid(
	source: PackedByteArray,
	width: int,
	height: int
) -> Array[PackedByteArray]:
	var levels: Array[PackedByteArray] = []
	levels.append(source)

	var src: PackedByteArray = source
	var w := width
	var h := height

	for _level in range(1, PYRAMID_LEVELS):
		var nw := maxi(1, w >> 1)
		var nh := maxi(1, h >> 1)
		var dst := PackedByteArray()
		dst.resize(nw * nh)

		for y in nh:
			var sy0 := mini(y << 1, h - 1)
			var sy1 := mini(sy0 + 1, h - 1)
			var row0 := sy0 * w
			var row1 := sy1 * w
			var dst_row := y * nw

			for x in nw:
				var sx0 := mini(x << 1, w - 1)
				var sx1 := mini(sx0 + 1, w - 1)

				dst[dst_row + x] = (
					int(src[row0 + sx0])
					+ int(src[row0 + sx1])
					+ int(src[row1 + sx0])
					+ int(src[row1 + sx1])
				) >> 2

		levels.append(dst)
		src = dst
		w = nw
		h = nh

	return levels


# ============================================================
# 特征点检测：Shi-Tomasi 最小特征值 + 网格非极大值抑制
# ============================================================

func _detect_features(
	image: PackedByteArray,
	width: int,
	height: int
) -> Array[Vector2]:
	var features: Array[Vector2] = []

	if width < FEATURE_MARGIN * 2 + 4:
		return features

	if height < FEATURE_MARGIN * 2 + 4:
		return features

	# 第一遍：Sobel 梯度 → 结构张量分量
	var gxx := PackedFloat32Array()
	var gyy := PackedFloat32Array()
	var gxy := PackedFloat32Array()

	gxx.resize(width * height)
	gyy.resize(width * height)
	gxy.resize(width * height)

	for y in range(1, height - 1):
		var row := y * width

		for x in range(1, width - 1):
			var i := row + x

			var a := int(image[i - width - 1])
			var b := int(image[i - width])
			var c := int(image[i - width + 1])
			var d := int(image[i - 1])
			var f := int(image[i + 1])
			var g := int(image[i + width - 1])
			var hh := int(image[i + width])
			var k := int(image[i + width + 1])

			var gx := float((c + 2 * f + k) - (a + 2 * d + g))
			var gy := float((g + 2 * hh + k) - (a + 2 * b + c))

			gxx[i] = gx * gx
			gyy[i] = gy * gy
			gxy[i] = gx * gy

	# 第二遍：3x3 窗口聚合 → 最小特征值 λmin（Shi-Tomasi）
	var responses := PackedFloat32Array()
	responses.resize(width * height)

	var margin := FEATURE_MARGIN
	var max_response := 0.0

	for y in range(margin, height - margin):
		var row := y * width

		for x in range(margin, width - margin):
			var sxx := 0.0
			var syy := 0.0
			var sxy := 0.0

			for oy in range(-1, 2):
				var r := (y + oy) * width + x

				sxx += gxx[r - 1] + gxx[r] + gxx[r + 1]
				syy += gyy[r - 1] + gyy[r] + gyy[r + 1]
				sxy += gxy[r - 1] + gxy[r] + gxy[r + 1]

			var diff := sxx - syy
			var lambda_min := 0.5 * (
				sxx + syy
				- sqrt(diff * diff + 4.0 * sxy * sxy)
			)

			responses[row + x] = lambda_min

			if lambda_min > max_response:
				max_response = lambda_min

	if max_response <= 0.0:
		return features

	var threshold := max_response * SHI_TOMASI_MIN_RATIO

	# 第三遍：网格内取最强角点。既做非极大值抑制，又让特征分布均匀。
	var picks: Array[Vector3] = []
	var cells_x := int(width / FEATURE_CELL)
	var cells_y := int(height / FEATURE_CELL)

	for cy in cells_y:
		for cx in cells_x:
			var x0 := cx * FEATURE_CELL
			var y0 := cy * FEATURE_CELL
			var xs := maxi(x0, margin)
			var ys := maxi(y0, margin)
			var xe := mini(x0 + FEATURE_CELL, width - margin)
			var ye := mini(y0 + FEATURE_CELL, height - margin)

			var best_value := 0.0
			var best_x := -1
			var best_y := -1

			for y in range(ys, ye):
				var row := y * width

				for x in range(xs, xe):
					var value := responses[row + x]

					if value > best_value:
						best_value = value
						best_x = x
						best_y = y

			if best_x >= 0 and best_value >= threshold:
				picks.append(
					Vector3(float(best_x), float(best_y), best_value)
				)

	if picks.size() > MAX_FEATURES:
		picks.sort_custom(_sort_by_response_desc)

	for pick in picks:
		if features.size() >= MAX_FEATURES:
			break

		features.append(Vector2(pick.x, pick.y))

	return features


func _sort_by_response_desc(a: Vector3, b: Vector3) -> bool:
	return a.z > b.z


# ============================================================
# SAD 块匹配
# ============================================================

# 热路径：内部完全不做边界检查。
# 调用方（_match_at_level）必须保证参考块中心 (cx, cy) 与
# 目标块中心 (cx+dx, cy+dy) 都满足「块完整落在图像内」。
func _sad(
	ref_img: PackedByteArray,
	tgt_img: PackedByteArray,
	width: int,
	cx: int,
	cy: int,
	dx: int,
	dy: int,
	block_radius: int
) -> int:
	var cost := 0
	var row_span := 2 * block_radius

	for py in range(-block_radius, block_radius + 1):
		var ref_index := (cy + py) * width + cx - block_radius
		var tgt_index := (
			(cy + py + dy) * width + cx - block_radius + dx
		)
		var end_index := ref_index + row_span

		while ref_index <= end_index:
			cost += absi(ref_img[ref_index] - tgt_img[tgt_index])
			ref_index += 1
			tgt_index += 1

	return cost


# 在金字塔某一层做块匹配（含大步长粗扫 + 亚像素精化）。
#   p     : 参考块中心（本层坐标）
#   guess : 初始位移估计（本层坐标）
#   返回   : 目标块相对于参考块的位移（含亚像素）
func _match_at_level(
	ref_img: PackedByteArray,
	tgt_img: PackedByteArray,
	width: int,
	height: int,
	p: Vector2,
	guess: Vector2,
	search_radius: int,
	block_radius: int,
	coarse_step: int
) -> Vector2:
	var cx := roundi(p.x)
	var cy := roundi(p.y)

	# 参考块越界：不精化，直接返回预测值
	if (
		cx < block_radius
		or cx > width - 1 - block_radius
		or cy < block_radius
		or cy > height - 1 - block_radius
	):
		return guess

	var gx := roundi(guess.x)
	var gy := roundi(guess.y)

	# 把搜索范围裁剪到「目标块不越界」的区间内，
	# 这样 _sad 内部就可以完全省掉边界检查。
	var dx_min := maxi(gx - search_radius, block_radius - cx)
	var dx_max := mini(
		gx + search_radius,
		width - 1 - block_radius - cx
	)
	var dy_min := maxi(gy - search_radius, block_radius - cy)
	var dy_max := mini(
		gy + search_radius,
		height - 1 - block_radius - cy
	)

	if dx_min > dx_max or dy_min > dy_max:
		return guess

	var best_cost := 1 << 30
	var best_dx := clampi(gx, dx_min, dx_max)
	var best_dy := clampi(gy, dy_min, dy_max)

	# 第一阶段：大位移先用大步长粗扫，避免全范围逐像素搜索
	if coarse_step > 1:
		var step_dy := dy_min

		while step_dy <= dy_max:
			var step_dx := dx_min

			while step_dx <= dx_max:
				var step_cost := _sad(
					ref_img,
					tgt_img,
					width,
					cx,
					cy,
					step_dx,
					step_dy,
					block_radius
				)

				if step_cost < best_cost:
					best_cost = step_cost
					best_dx = step_dx
					best_dy = step_dy

				step_dx += coarse_step

			step_dy += coarse_step

		dx_min = maxi(best_dx - coarse_step, dx_min)
		dx_max = mini(best_dx + coarse_step, dx_max)
		dy_min = maxi(best_dy - coarse_step, dy_min)
		dy_max = mini(best_dy + coarse_step, dy_max)

	# 第二阶段：步长 1 精扫
	for dy in range(dy_min, dy_max + 1):
		for dx in range(dx_min, dx_max + 1):
			var cost := _sad(
				ref_img,
				tgt_img,
				width,
				cx,
				cy,
				dx,
				dy,
				block_radius
			)

			if cost < best_cost:
				best_cost = cost
				best_dx = dx
				best_dy = dy

	# 亚像素：对 SAD 曲面做一维抛物线拟合
	var sub_x := 0.0
	var sub_y := 0.0

	if best_dx > dx_min and best_dx < dx_max:
		var left := _sad(
			ref_img, tgt_img, width, cx, cy,
			best_dx - 1, best_dy, block_radius
		)
		var right := _sad(
			ref_img, tgt_img, width, cx, cy,
			best_dx + 1, best_dy, block_radius
		)

		sub_x = _parabolic_offset(
			float(left),
			float(best_cost),
			float(right)
		)

	if best_dy > dy_min and best_dy < dy_max:
		var up := _sad(
			ref_img, tgt_img, width, cx, cy,
			best_dx, best_dy - 1, block_radius
		)
		var down := _sad(
			ref_img, tgt_img, width, cx, cy,
			best_dx, best_dy + 1, block_radius
		)

		sub_y = _parabolic_offset(
			float(up),
			float(best_cost),
			float(down)
		)

	return Vector2(
		float(best_dx) + sub_x,
		float(best_dy) + sub_y
	)


# 一维抛物线顶点偏移量，裁剪到 ±1 像素
func _parabolic_offset(
	left: float,
	center: float,
	right: float
) -> float:
	var denominator := left - 2.0 * center + right

	if absf(denominator) < 1.0e-6:
		return 0.0

	return clampf(
		0.5 * (left - right) / denominator,
		-1.0,
		1.0
	)


# 由粗到细跟踪单个特征点，返回 L0 尺度的位移
func _track_l0(
	prev_pyr: Array[PackedByteArray],
	curr_pyr: Array[PackedByteArray],
	dims: Array[Vector2i],
	start_l0: Vector2,
	predict_l0: Vector2
) -> Vector2:
	var disp := predict_l0

	for level in range(COARSE_LEVEL, -1, -1):
		var level_dims: Vector2i = dims[level]
		var scale := float(1 << level)
		var p_level := start_l0 / scale
		var guess_level := disp / scale

		var search_radius: int = int(SEARCH_RADII[level])
		var block_radius: int = int(BLOCK_RADII[level])
		var coarse_step := 1

		if level == COARSE_LEVEL:
			coarse_step = COARSE_STEP_LEVEL2

		var delta := _match_at_level(
			prev_pyr[level],
			curr_pyr[level],
			level_dims.x,
			level_dims.y,
			p_level,
			guess_level,
			search_radius,
			block_radius,
			coarse_step
		)

		disp = delta * scale

	return disp


# ============================================================
# 4 自由度相似变换：RANSAC + 最小二乘
# ============================================================
#
# 模型（以画面中心为原点，x 向右、y 向下）：
#   u = tx + p*(x-cx) - q*(y-cy)
#   v = ty + q*(x-cx) + p*(y-cy)
#
#   tx, ty —— 平移（像素/帧）
#   p      —— 膨胀率（>0 画面扩张 = 前进）
#   q      —— 滚转（>0 图像顺时针）
#
# 该模型把「横向平移」与「前后平移（膨胀）」天然解耦，
# 这正是旧版「以画面中心做径向投影」做不到的。

func _predict_flow(p: Vector2, center: Vector2) -> Vector2:
	var ax := p.x - center.x
	var ay := p.y - center.y

	return Vector2(
		_model_tx + _model_p * ax - _model_q * ay,
		_model_ty + _model_q * ax + _model_p * ay
	)


func _fit_similarity(
	src: Array[Vector2],
	flow: Array[Vector2],
	center: Vector2
) -> Dictionary:
	var count := src.size()

	if count < 3:
		return {"valid": false, "inliers": 0}

	var best_inliers := PackedInt32Array()
	var best_count := 0

	# RANSAC：2 个点正好确定 4 个自由度，最小样本取 2
	for _iteration in RANSAC_ITERATIONS:
		var index_a := _rng.randi_range(0, count - 1)
		var index_b := _rng.randi_range(0, count - 1)

		if index_a == index_b:
			continue

		if (
			src[index_a].distance_to(src[index_b])
			< RANSAC_MIN_BASELINE
		):
			continue

		var sample := PackedInt32Array([index_a, index_b])
		var params := _solve_ls(src, flow, sample, center)

		if params.is_empty():
			continue

		var inliers := _collect_inliers(
			src,
			flow,
			center,
			params,
			RANSAC_INLIER_DIST
		)

		if inliers.size() > best_count:
			best_count = inliers.size()
			best_inliers = inliers

	if best_count < MIN_INLIERS:
		return _translation_only(src, flow)

	# 用全部内点重解一次，进一步提高精度
	var final_params := _solve_ls(src, flow, best_inliers, center)

	if final_params.is_empty():
		return _translation_only(src, flow)

	return {
		"valid": true,
		"tx": final_params[0],
		"ty": final_params[1],
		"p_exp": final_params[2],
		"q_rot": final_params[3],
		"inliers": best_count,
		"rms": _residual_rms(
			src,
			flow,
			center,
			final_params,
			best_inliers
		)
	}


# 最小二乘：法方程 + 高斯消元
func _solve_ls(
	src: Array[Vector2],
	flow: Array[Vector2],
	indices: PackedInt32Array,
	center: Vector2
) -> Array:
	if indices.size() < 2:
		return []

	var matrix := PackedFloat32Array()
	var rhs := PackedFloat32Array()
	matrix.resize(16)
	rhs.resize(4)

	for k in indices.size():
		var i := indices[k]
		var ax := src[i].x - center.x
		var ay := src[i].y - center.y

		# u 行：[1, 0, ax, -ay]
		_accumulate_row(
			matrix,
			rhs,
			1.0,
			0.0,
			ax,
			-ay,
			flow[i].x
		)

		# v 行：[0, 1, ay, ax]
		_accumulate_row(
			matrix,
			rhs,
			0.0,
			1.0,
			ay,
			ax,
			flow[i].y
		)

	return _solve4(matrix, rhs)


func _accumulate_row(
	matrix: PackedFloat32Array,
	rhs: PackedFloat32Array,
	j0: float,
	j1: float,
	j2: float,
	j3: float,
	target: float
) -> void:
	matrix[0] += j0 * j0
	matrix[1] += j0 * j1
	matrix[2] += j0 * j2
	matrix[3] += j0 * j3

	matrix[4] += j1 * j0
	matrix[5] += j1 * j1
	matrix[6] += j1 * j2
	matrix[7] += j1 * j3

	matrix[8] += j2 * j0
	matrix[9] += j2 * j1
	matrix[10] += j2 * j2
	matrix[11] += j2 * j3

	matrix[12] += j3 * j0
	matrix[13] += j3 * j1
	matrix[14] += j3 * j2
	matrix[15] += j3 * j3

	rhs[0] += j0 * target
	rhs[1] += j1 * target
	rhs[2] += j2 * target
	rhs[3] += j3 * target


# 4x4 高斯消元（部分主元）。
# 返回 [tx, ty, p, q]，奇异时返回空数组。
func _solve4(
	matrix: PackedFloat32Array,
	rhs: PackedFloat32Array
) -> Array:
	var augmented := PackedFloat32Array()
	augmented.resize(20)

	for row in 4:
		for column in 4:
			augmented[row * 5 + column] = (
				matrix[row * 4 + column]
			)

		augmented[row * 5 + 4] = rhs[row]

	for column in 4:
		var pivot_row := column
		var pivot_value := absf(
			augmented[column * 5 + column]
		)

		for row in range(column + 1, 4):
			var value := absf(augmented[row * 5 + column])

			if value > pivot_value:
				pivot_value = value
				pivot_row = row

		if pivot_value < 1.0e-9:
			return []

		if pivot_row != column:
			for c in range(column, 5):
				var tmp := augmented[column * 5 + c]
				augmented[column * 5 + c] = (
					augmented[pivot_row * 5 + c]
				)
				augmented[pivot_row * 5 + c] = tmp

		var diagonal := augmented[column * 5 + column]

		for c in range(column, 5):
			augmented[column * 5 + c] /= diagonal

		for row in 4:
			if row == column:
				continue

			var factor := augmented[row * 5 + column]

			if absf(factor) < 1.0e-12:
				continue

			for c in range(column, 5):
				augmented[row * 5 + c] -= (
					factor * augmented[column * 5 + c]
				)

	return [
		augmented[4],
		augmented[9],
		augmented[14],
		augmented[19]
	]


func _collect_inliers(
	src: Array[Vector2],
	flow: Array[Vector2],
	center: Vector2,
	params: Array,
	threshold: float
) -> PackedInt32Array:
	var inliers := PackedInt32Array()
	var limit := threshold * threshold

	var tx := float(params[0])
	var ty := float(params[1])
	var expansion := float(params[2])
	var rotation := float(params[3])

	for i in src.size():
		var ax := src[i].x - center.x
		var ay := src[i].y - center.y

		var du := flow[i].x - (
			tx + expansion * ax - rotation * ay
		)
		var dv := flow[i].y - (
			ty + rotation * ax + expansion * ay
		)

		if du * du + dv * dv <= limit:
			inliers.append(i)

	return inliers


func _residual_rms(
	src: Array[Vector2],
	flow: Array[Vector2],
	center: Vector2,
	params: Array,
	indices: PackedInt32Array
) -> float:
	if indices.is_empty():
		return 0.0

	var tx := float(params[0])
	var ty := float(params[1])
	var expansion := float(params[2])
	var rotation := float(params[3])

	var sum := 0.0

	for k in indices.size():
		var i := indices[k]
		var ax := src[i].x - center.x
		var ay := src[i].y - center.y

		var du := flow[i].x - (
			tx + expansion * ax - rotation * ay
		)
		var dv := flow[i].y - (
			ty + rotation * ax + expansion * ay
		)

		sum += du * du + dv * dv

	return sqrt(sum / float(indices.size()))


# 退化路径：RANSAC 找不到足够内点时，只输出鲁棒平移，
# 并把膨胀/旋转置 0（宁可不给前进信号，也不给错误信号）。
func _translation_only(
	src: Array[Vector2],
	flow: Array[Vector2]
) -> Dictionary:
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()

	xs.resize(flow.size())
	ys.resize(flow.size())

	for i in flow.size():
		xs[i] = flow[i].x
		ys[i] = flow[i].y

	return {
		"valid": src.size() >= MIN_INLIERS,
		"tx": _median_sorted(xs),
		"ty": _median_sorted(ys),
		"p_exp": 0.0,
		"q_rot": 0.0,
		"inliers": src.size(),
		"rms": 0.0
	}


func _median_sorted(values: PackedFloat32Array) -> float:
	var count := values.size()

	if count == 0:
		return 0.0

	values.sort()

	var middle := count >> 1

	if count % 2 == 0:
		return (values[middle - 1] + values[middle]) * 0.5

	return values[middle]


# ============================================================
# 安全退出后台线程
# ============================================================

func _exit_tree() -> void:
	_flow_mutex.lock()
	_flow_thread_running = false
	_flow_mutex.unlock()

	# 唤醒正在等待的线程，让它能够退出
	_flow_semaphore.post()

	if _flow_thread.is_started():
		_flow_thread.wait_to_finish()
