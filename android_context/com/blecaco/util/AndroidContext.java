package com.blecaco.util;

import android.content.Context;

import java.lang.reflect.Method;
import java.util.Collection;

/**
 * 让 GDScript 能拿到 Android Context 的小工具。
 *
 * Godot 4 的 Engine.get_singleton("AndroidRuntime") 在 GDScript 侧不暴露
 * Java 方法（get_method_list 只有 Object 方法），因此这里用一条干净的路径：
 *
 *   org.godotengine.godot.plugin.GodotPluginRegistry.getPluginRegistry() 是 public static，
 *   任何已注册的 GodotPlugin（例如 NativeCameraPlugin）内部都持有 Activity
 *   （GodotPlugin.getActivity() 为 protected，用反射调用即可）。
 *
 * 全程只依赖 public API + 反射，不碰 Android 隐藏 API。
 *
 * GDScript 用法：
 *   var helper = JavaClassWrapper.wrap("com.blecaco.util.AndroidContext")
 *   var ctx = helper.getContext()
 *
 * 注意：方法名不能叫 get()，否则会与 GDScript 的 Object.get(property) 冲突。
 */
public final class AndroidContext {

    private static Context cached = null;

    private AndroidContext() {
    }

    /** 返回 android.content.Context，失败返回 null。 */
    public static Object getContext() {
        if (cached != null) {
            return cached;
        }

        try {
            Class<?> registryClass = Class.forName(
                    "org.godotengine.godot.plugin.GodotPluginRegistry");

            Object registry = registryClass
                    .getMethod("getPluginRegistry")
                    .invoke(null);

            if (registry == null) {
                return null;
            }

            Object plugins = registryClass
                    .getMethod("getAllPlugins")
                    .invoke(registry);

            if (!(plugins instanceof Collection)) {
                return null;
            }

            for (Object plugin : (Collection<?>) plugins) {
                Context context = activityFromPlugin(plugin);

                if (context != null) {
                    cached = context;
                    return cached;
                }
            }
        } catch (Throwable ignored) {
            // 交给调用方处理
        }

        return null;
    }

    /** 反射调用 GodotPlugin（或其父类）的 protected getActivity()。 */
    private static Context activityFromPlugin(Object plugin) {
        Class<?> cls = plugin.getClass();

        while (cls != null) {
            try {
                Method method = cls.getDeclaredMethod("getActivity");
                method.setAccessible(true);

                Object value = method.invoke(plugin);

                if (value instanceof Context) {
                    return (Context) value;
                }
            } catch (Throwable ignored) {
                // 继续往父类找
            }

            cls = cls.getSuperclass();
        }

        return null;
    }
}
