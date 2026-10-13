@tool
extends EditorPlugin
# OpenVINS 的 Godot Android 导出插件。
#
# 作用：导出期把
#   res://addons/OpenVINSPlugin/bin/<build_type>/OpenVINSPlugin-<build_type>.aar
# 交给 Godot 的 gradle 构建，最终进入 APK 的 classes.dex 与 lib/arm64-v8a/。
# 与 addons/NativeCameraPlugin 的做法完全一致。
#
# AAR 由原生工程生成（不是手写的）：
#   cd /home/one/open_vins_mobile && ./plugin/sync_to_godot.sh

const PLUGIN_NAME: String = "OpenVINSPlugin"

var android_export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	android_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(android_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(android_export_plugin)
	android_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	var _plugin_name = PLUGIN_NAME


	func _supports_platform(
		a_platform: EditorExportPlatform
	) -> bool:
		return a_platform is EditorExportPlatformAndroid


	func _get_name() -> String:
		return _plugin_name


	func _get_android_libraries(
		_a_platform: EditorExportPlatform,
		a_debug: bool
	) -> PackedStringArray:
		if a_debug:
			return PackedStringArray([
				"%s/bin/debug/%s-debug.aar"
				% [_plugin_name, _plugin_name]
			])

		return PackedStringArray([
			"%s/bin/release/%s-release.aar"
			% [_plugin_name, _plugin_name]
		])


	func _get_android_dependencies(
		_a_platform: EditorExportPlatform,
		_a_debug: bool
	) -> PackedStringArray:
		# AAR 自带 classes.jar 与所需 .so（opencv / boost / libc++_shared），
		# 不需要额外的远程依赖。
		return PackedStringArray([])
