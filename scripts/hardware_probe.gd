extends Control
# 硬件探针场景。
#
# 目的：在完全不知道手机品牌/型号的前提下，把 Android 能自动提供的
# VIO 相关硬件数据全部读出来并显示，用于判断「最大通用性」路线是否成立。
#
# 数据来自 addons/hardware-probe.jar 里的 com.blecaco.probe.HardwareProbe。
# 结果同时会 print 到控制台（Android 上即 logcat）。

const PROBE_CLASS := "com.blecaco.probe.HardwareProbe"

@onready var output: TextEdit = $Output


func _ready() -> void:
	var result := _collect()

	output.text = result

	# logcat 单条消息有长度上限，逐行打印避免被截断
	print("[HardwareProbe] ===== BEGIN =====")

	for line in result.split("\n"):
		print("[HardwareProbe] ", line)

	print("[HardwareProbe] ===== END =====")

	# 同时落盘，方便用 adb run-as 完整取出
	var file := FileAccess.open(
		"user://hardware_probe.txt",
		FileAccess.WRITE
	)

	if file != null:
		file.store_string(result)
		file.close()
		print("[HardwareProbe] 已写入 user://hardware_probe.txt")


func _collect() -> String:
	if not OS.has_feature("android"):
		return "非 Android 平台，无法探测硬件。"

	var probe = JavaClassWrapper.wrap(PROBE_CLASS)

	if probe == null:
		return (
			"JavaClassWrapper.wrap 失败：" + PROBE_CLASS + "\n"
			+ "请确认 addons/hardware-probe.jar 已打包进 APK"
		)

	var context = _get_android_context()
	var text: String

	if context != null:
		text = str(probe.probe(context))
	else:
		# Java 侧会用 GodotPluginRegistry 自己解析 Context，这里拿不到不算错
		text = str(probe.probe())

	return text


# 不同 Godot 版本对 AndroidRuntime 的方法名不同，
# 且 has_method() 对 Java 包装对象不可靠 —— 改为枚举方法名后按需调用。
func _get_android_context():
	var runtime := Engine.get_singleton("AndroidRuntime")

	if runtime == null:
		print("[HardwareProbe] 找不到 AndroidRuntime 单例；现有单例=",
			Engine.get_singleton_list())
		return null

	var names := PackedStringArray()

	for method_info in runtime.get_method_list():
		names.append(str(method_info.get("name", "")))

	print("[HardwareProbe] AndroidRuntime 方法列表=", names)

	# 优先取 Activity，其次取 ApplicationContext
	for keyword in ["ctivity", "ontext"]:
		for method_name in names:
			var lower := method_name.to_lower()

			if lower.find(keyword.to_lower()) == -1:
				continue

			if lower.begins_with("set") or lower.begins_with("remove"):
				continue

			var value = runtime.call(method_name)

			if value != null:
				print("[HardwareProbe] Context 来源：", method_name)
				return value

	print("[HardwareProbe] 方法列表里没有可用的 Context 方法")
	return null

