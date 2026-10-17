@tool
extends EditorPlugin

# 只做一件事：把 bin/<variant>/OpenVINSGodot-<variant>.aar 挂进 Godot 的 Android 导出。
# ⚠️ 路径写法照 NativeCameraPlugin：相对 res://addons/ 的路径。

const PLUGIN_NAME: String = "OpenVINSGodot"

var _android_export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	_android_export_plugin = AndroidExportPlugin.new()
	add_export_plugin(_android_export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(_android_export_plugin)
	_android_export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	var _plugin_name = PLUGIN_NAME

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		if debug:
			return PackedStringArray(["%s/bin/debug/%s-debug.aar" % [_plugin_name, _plugin_name]])
		return PackedStringArray(["%s/bin/release/%s-release.aar" % [_plugin_name, _plugin_name]])

	func _get_android_dependencies(platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray()

	func _get_name() -> String:
		return _plugin_name
