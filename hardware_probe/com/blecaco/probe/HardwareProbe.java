package com.blecaco.probe;

import android.content.Context;
import android.graphics.Rect;
import android.hardware.Sensor;
import android.hardware.SensorManager;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.os.Build;
import android.util.Size;
import android.util.SizeF;

import java.util.List;

/**
 * Blecaco 硬件探针（不假设任何机型）。
 *
 * 目的：验证「最大通用性」路线能否成立 —— 即在完全不知道手机品牌/型号的前提下，
 * 到底能从 Android 自动读到多少 VIO 所需的硬件数据。
 *
 * 纯静态方法、零第三方依赖，通过 JavaClassWrapper 调用：
 *   var probe = JavaClassWrapper.wrap("com.blecaco.probe.HardwareProbe")
 *   print(probe.probe(activity))
 *
 * ctx 为 null 时仍会输出 Build 信息（用于验证 jar 是否加载成功）。
 */
public final class HardwareProbe {

    private HardwareProbe() {
    }

    /** 记录 Context 是从哪条路径拿到的，便于排查。 */
    private static String contextSource = "none";

    /**
     * 自己想办法拿到 Context —— 不依赖 Godot 侧传入。
     *
     * 路径：org.godotengine.godot.plugin.GodotPluginRegistry 是 public static，
     * 而任何已注册的 GodotPlugin（例如 NativeCameraPlugin）内部持有 Activity。
     * 全程只用 public API + 反射，不碰 Android 隐藏 API。
     */
    private static Context resolveContext(Object hint) {
        if (hint instanceof Context) {
            contextSource = "arg";
            return (Context) hint;
        }

        try {
            Class<?> registryClass = Class.forName(
                    "org.godotengine.godot.plugin.GodotPluginRegistry");

            Object registry = registryClass
                    .getMethod("getPluginRegistry")
                    .invoke(null);

            if (registry == null) {
                contextSource = "registry=null";
                return null;
            }

            Object plugins = registryClass
                    .getMethod("getAllPlugins")
                    .invoke(registry);

            if (!(plugins instanceof java.util.Collection)) {
                contextSource = "plugins=null";
                return null;
            }

            for (Object plugin : (java.util.Collection<?>) plugins) {
                Context ctx = activityFromPlugin(plugin);

                if (ctx != null) {
                    contextSource = "GodotPlugin:"
                            + plugin.getClass().getSimpleName();
                    return ctx;
                }
            }

            contextSource = "no-plugin-activity";
        } catch (Throwable t) {
            contextSource = "registry-err:" + t.getClass().getSimpleName();
        }

        return null;
    }

    /** 反射调用 GodotPlugin（或其父类）的 protected getActivity()。 */
    private static Context activityFromPlugin(Object plugin) {
        Class<?> cls = plugin.getClass();

        while (cls != null) {
            try {
                java.lang.reflect.Method m = cls.getDeclaredMethod("getActivity");
                m.setAccessible(true);

                Object value = m.invoke(plugin);

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

    /** 主入口。contextObj 应为 android.content.Context。 */
    public static String probe(Object contextObj) {
        StringBuilder sb = new StringBuilder(4096);

        Context ctx = resolveContext(contextObj);

        sb.append("==== BLECACO HARDWARE PROBE ====\n");
        sb.append("context=").append(ctx != null ? "OK" : "NULL")
                .append(" via=").append(contextSource).append('\n');

        appendBuild(sb);

        if (ctx == null) {
            sb.append("(context 为空，跳过相机/传感器探测)\n");
            return sb.toString();
        }

        try {
            appendCameras(sb, ctx);
        } catch (Throwable t) {
            sb.append("camera ERROR: ").append(t).append('\n');
        }

        try {
            appendSensors(sb, ctx);
        } catch (Throwable t) {
            sb.append("sensor ERROR: ").append(t).append('\n');
        }

        appendVerdict(sb);
        return sb.toString();
    }

    /** 无参重载：拿不到 Context 时兜底调用。 */
    public static String probe() {
        return probe(null);
    }

    // ---------------------------------------------------------------
    // Build / 设备信息
    // ---------------------------------------------------------------

    private static void appendBuild(StringBuilder sb) {
        sb.append("MANUFACTURER=").append(Build.MANUFACTURER).append('\n');
        sb.append("BRAND=").append(Build.BRAND).append('\n');
        sb.append("MODEL=").append(Build.MODEL).append('\n');
        sb.append("DEVICE=").append(Build.DEVICE).append('\n');
        sb.append("SDK_INT=").append(Build.VERSION.SDK_INT).append('\n');
        sb.append("RELEASE=").append(Build.VERSION.RELEASE).append('\n');
    }

    // ---------------------------------------------------------------
    // Camera2
    // ---------------------------------------------------------------

    private static void appendCameras(StringBuilder sb, Context ctx) throws Exception {
        CameraManager cm = (CameraManager) ctx.getSystemService(Context.CAMERA_SERVICE);
        if (cm == null) {
            sb.append("CameraManager=NULL\n");
            return;
        }

        String[] ids = cm.getCameraIdList();
        sb.append("camera_count=").append(ids.length).append('\n');

        for (String id : ids) {
            CameraCharacteristics c = cm.getCameraCharacteristics(id);
            if (c == null) {
                continue;
            }

            Integer facing = c.get(CameraCharacteristics.LENS_FACING);
            sb.append("-- camera id=").append(id)
                    .append(" facing=").append(facing)
                    .append(facingLabel(facing)).append('\n');

            sb.append("   SENSOR_ORIENTATION=")
                    .append(c.get(CameraCharacteristics.SENSOR_ORIENTATION)).append('\n');
            sb.append("   HARDWARE_LEVEL=")
                    .append(c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)).append('\n');

            float[] focal = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS);
            sb.append("   FOCAL_MM=").append(fmt(focal)).append('\n');

            SizeF ps = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE);
            sb.append("   PHYSICAL_SIZE_MM=").append(sizeF(ps)).append('\n');

            Size px = c.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE);
            sb.append("   PIXEL_ARRAY=").append(size(px)).append('\n');

            Rect act = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
            sb.append("   ACTIVE_ARRAY=").append(rect(act)).append('\n');

            float[] intr = c.get(CameraCharacteristics.LENS_INTRINSIC_CALIBRATION);
            sb.append("   LENS_INTRINSIC_CALIBRATION=").append(fmt(intr)).append('\n');

            float[] dist = c.get(CameraCharacteristics.LENS_DISTORTION);
            sb.append("   LENS_DISTORTION=").append(fmt(dist)).append('\n');

            appendPose(sb, c);

            appendExtrinsicCandidate(sb, c, facing);

            appendDerivedIntrinsics(sb, focal, ps, act);
        }
    }

    /** API 28+ 才有的相机相对设备位姿（推导 T_cam_imu 初值最想要的数据）。 */
    private static void appendPose(StringBuilder sb, CameraCharacteristics c) {
        if (Build.VERSION.SDK_INT < 28) {
            sb.append("   LENS_POSE_*=NeedsApi28(device=")
                    .append(Build.VERSION.SDK_INT).append(")\n");
            return;
        }

        try {
            float[] rot = c.get(CameraCharacteristics.LENS_POSE_ROTATION);
            sb.append("   LENS_POSE_ROTATION=").append(fmt(rot))
                    .append("  (格式 x,y,z,w)").append('\n');

            float[] tr = c.get(CameraCharacteristics.LENS_POSE_TRANSLATION);
            sb.append("   LENS_POSE_TRANSLATION=").append(fmt(tr)).append('\n');

            appendPoseVerdict(sb, rot);

            Integer ref = c.get(CameraCharacteristics.LENS_POSE_REFERENCE);
            sb.append("   LENS_POSE_REFERENCE=").append(ref)
                    .append(" (0=PRIMARY_CAMERA,1=GYROSCOPE,2=UNDECIDED,3=UNDEFINED)").append('\n');
        } catch (Throwable t) {
            sb.append("   LENS_POSE_* ERROR: ").append(t).append('\n');
        }
    }

    /**
     * 无 HAL 内参时，用 焦距(mm) + 传感器物理尺寸(mm) 反推像素内参。
     * 仅为一阶估计，用于判断该兜底路线是否可用。
     */
    private static void appendDerivedIntrinsics(
            StringBuilder sb, float[] focal, SizeF ps, Rect act) {

        if (focal == null || focal.length == 0 || ps == null || act == null) {
            sb.append("   derived_intrinsics=UNAVAILABLE\n");
            return;
        }

        float f = focal[0];
        float sw = ps.getWidth();
        float sh = ps.getHeight();

        if (f <= 0f || sw <= 0f || sh <= 0f) {
            sb.append("   derived_intrinsics=UNAVAILABLE(bad_value)\n");
            return;
        }

        int aw = act.width();
        int ah = act.height();

        if (aw <= 0 || ah <= 0) {
            sb.append("   derived_intrinsics=UNAVAILABLE(bad_array)\n");
            return;
        }

        float fx = f * (aw / sw);
        float fy = f * (ah / sh);
        float cx = aw / 2.0f;
        float cy = ah / 2.0f;

        sb.append("   derived_intrinsics_native=")
                .append(String.format("fx=%.2f fy=%.2f cx=%.2f cy=%.2f (array %dx%d)",
                        fx, fy, cx, cy, aw, ah)).append('\n');

        float sx = 640.0f / aw;
        float sy = 480.0f / ah;
        sb.append("   derived_intrinsics_640x480=")
                .append(String.format("fx=%.2f fy=%.2f cx=%.2f cy=%.2f",
                        fx * sx, fy * sy, cx * sx, cy * sy)).append('\n');
    }

    // ---------------------------------------------------------------
    // 传感器（IMU）
    // ---------------------------------------------------------------

    private static void appendSensors(StringBuilder sb, Context ctx) {
        SensorManager sm = (SensorManager) ctx.getSystemService(Context.SENSOR_SERVICE);
        if (sm == null) {
            sb.append("SensorManager=NULL\n");
            return;
        }

        List<Sensor> all = sm.getSensorList(Sensor.TYPE_ALL);
        sb.append("sensor_count=").append(all == null ? 0 : all.size()).append('\n');

        if (all == null) {
            return;
        }

        for (Sensor s : all) {
            int t = s.getType();

            boolean wanted = (t == Sensor.TYPE_ACCELEROMETER)
                    || (t == Sensor.TYPE_GYROSCOPE)
                    || (t == Sensor.TYPE_LINEAR_ACCELERATION)
                    || (t == Sensor.TYPE_ROTATION_VECTOR);

            if (!wanted) {
                continue;
            }

            sb.append("-- sensor type=").append(t)
                    .append(" name=").append(s.getName())
                    .append(" vendor=").append(s.getVendor())
                    .append(" version=").append(s.getVersion())
                    .append('\n');
            sb.append("   resolution=").append(s.getResolution())
                    .append(" maxRange=").append(s.getMaximumRange())
                    .append(" minDelayUs=").append(s.getMinDelay())
                    .append(" power=").append(s.getPower())
                    .append('\n');
        }
    }

    // ---------------------------------------------------------------
    // 结论提示
    // ---------------------------------------------------------------

    private static void appendVerdict(StringBuilder sb) {
        sb.append("\n---- 判定要点 ----\n");
        sb.append("  1) LENS_INTRINSIC_CALIBRATION 非 null -> 内参可直接用\n");
        sb.append("  2) 若 null 但 FOCAL_MM+PHYSICAL_SIZE_MM+ACTIVE_ARRAY 齐全 -> 内参可推导\n");
        sb.append("  3) LENS_POSE_ROTATION 非 null -> 外参初值可直接用(最理想)\n");
        sb.append("  4) 否则用 SENSOR_ORIENTATION 推导外参初值(残差待验证)\n");
        sb.append("  5) sensor name/vendor -> 按 IMU 芯片型号查噪声参数\n");
    }

    // ---------------------------------------------------------------
    // 外参：判定 + 推导（L3）
    // ---------------------------------------------------------------

    private static String facingLabel(Integer f) {
        if (f == null) {
            return "(unknown)";
        }
        if (f == 0) {
            return "(FRONT)";
        }
        if (f == 1) {
            return "(BACK)";
        }
        if (f == 2) {
            return "(EXTERNAL)";
        }
        return "(?)";
    }

    /**
     * 判断 HAL 给的 LENS_POSE_ROTATION 是"真标定"还是"默认填充"。
     *
     * 经验：后摄在 SENSOR_ORIENTATION=0 时的相机→设备关系是「180° 绕 X 轴」，
     * 对应四元数 (x,y,z,w) = (1,0,0,0)。若无论 SENSOR_ORIENTATION 是多少，
     * 设备都返回这个值，基本可判定是默认填充而非真实标定。
     */
    private static void appendPoseVerdict(StringBuilder sb, float[] rot) {
        if (rot == null || rot.length < 4) {
            sb.append("   [判定] 无 LENS_POSE_ROTATION\n");
            return;
        }

        float x = rot[0];
        float y = rot[1];
        float z = rot[2];
        float w = rot[3];

        boolean is180AboutX = Math.abs(x) > 0.999f
                && Math.abs(y) < 1e-3f
                && Math.abs(z) < 1e-3f
                && Math.abs(w) < 1e-3f;

        boolean isIdentity = Math.abs(w) > 0.999f
                && Math.abs(x) < 1e-3f
                && Math.abs(y) < 1e-3f
                && Math.abs(z) < 1e-3f;

        if (is180AboutX) {
            sb.append("   [判定] = 180°绕X => 等于「后摄 S=0 基准」；"
                    + "若与 SENSOR_ORIENTATION 不符则为默认填充值\n");
        } else if (isIdentity) {
            sb.append("   [判定] = 单位四元数 => 物理上不合理"
                    + "（后摄光轴应朝设备背面），判为无效\n");
        } else {
            sb.append("   [判定] = 非平凡值 => 可能是真实标定\n");
        }
    }

    /**
     * 用 SENSOR_ORIENTATION + Android 约定推导相机↔IMU 外参「候选初值」（只对后摄）。
     *
     * 约定：
     *   - Android IMU 坐标系 = 设备自然方向系：X 右 / Y 上 / Z 朝屏幕外
     *   - 相机(OpenCV)坐标系：X 右 / Y 下 / Z 光轴朝前
     *   - 后摄光轴朝设备背面 => Z_cam = -Z_dev
     *
     * 推导：R_cam_imu = Rz(S) * diag(1, -1, -1)      S = SENSOR_ORIENTATION
     *   S=0 时退化为 180°绕X，与 Android 自身的基准关系一致。
     *
     * 注意：这是「未经验证的候选值」，最终必须靠 VIO 收敛来确认。
     */
    private static void appendExtrinsicCandidate(
            StringBuilder sb, CameraCharacteristics c, Integer facing) {

        if (facing == null || facing != 1) {
            return; // 只对后摄推导
        }

        Integer so = c.get(CameraCharacteristics.SENSOR_ORIENTATION);

        if (so == null) {
            return;
        }

        double s = Math.toRadians(so % 360);
        double cs = Math.cos(s);
        double sn = Math.sin(s);

        double[][] rz = {
                {cs, -sn, 0.0},
                {sn, cs, 0.0},
                {0.0, 0.0, 1.0}
        };
        double[][] base = {
                {1.0, 0.0, 0.0},
                {0.0, -1.0, 0.0},
                {0.0, 0.0, -1.0}
        };

        double[][] r = mul3(rz, base);

        sb.append("   [候选外参 R_cam_imu] (SENSOR_ORIENTATION=")
                .append(so).append(", 未验证)\n");

        for (int i = 0; i < 3; i++) {
            sb.append("      ")
                    .append(String.format("[%+.4f %+.4f %+.4f]",
                            r[i][0], r[i][1], r[i][2]))
                    .append('\n');
        }

        double[] q = matToQuat(r);
        sb.append(String.format(
                "      四元数(w,x,y,z)=[%.6f, %.6f, %.6f, %.6f]%n",
                q[0], q[1], q[2], q[3]));
    }

    private static double[][] mul3(double[][] a, double[][] b) {
        double[][] out = new double[3][3];

        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                double sum = 0.0;

                for (int k = 0; k < 3; k++) {
                    sum += a[i][k] * b[k][j];
                }

                out[i][j] = sum;
            }
        }

        return out;
    }

    /** 3x3 旋转矩阵 -> 四元数 (w,x,y,z)。 */
    private static double[] matToQuat(double[][] r) {
        double tr = r[0][0] + r[1][1] + r[2][2];
        double w;
        double x;
        double y;
        double z;

        if (tr > 0.0) {
            double s = Math.sqrt(tr + 1.0) * 2.0;
            w = 0.25 * s;
            x = (r[2][1] - r[1][2]) / s;
            y = (r[0][2] - r[2][0]) / s;
            z = (r[1][0] - r[0][1]) / s;
        } else if (r[0][0] > r[1][1] && r[0][0] > r[2][2]) {
            double s = Math.sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2.0;
            w = (r[2][1] - r[1][2]) / s;
            x = 0.25 * s;
            y = (r[0][1] + r[1][0]) / s;
            z = (r[0][2] + r[2][0]) / s;
        } else if (r[1][1] > r[2][2]) {
            double s = Math.sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2.0;
            w = (r[0][2] - r[2][0]) / s;
            x = (r[0][1] + r[1][0]) / s;
            y = 0.25 * s;
            z = (r[1][2] + r[2][1]) / s;
        } else {
            double s = Math.sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2.0;
            w = (r[1][0] - r[0][1]) / s;
            x = (r[0][2] + r[2][0]) / s;
            y = (r[1][2] + r[2][1]) / s;
            z = 0.25 * s;
        }

        double n = Math.sqrt(w * w + x * x + y * y + z * z);

        return new double[]{w / n, x / n, y / n, z / n};
    }

    // ---------------------------------------------------------------
    // 小工具
    // ---------------------------------------------------------------

    private static String fmt(float[] a) {
        if (a == null) {
            return "null";
        }

        StringBuilder sb = new StringBuilder("[");

        for (int i = 0; i < a.length; i++) {
            if (i > 0) {
                sb.append(", ");
            }
            sb.append(String.format("%.6f", a[i]));
        }

        return sb.append(']').toString();
    }

    private static String sizeF(SizeF s) {
        return s == null ? "null" : String.format("%.4fx%.4f", s.getWidth(), s.getHeight());
    }

    private static String size(Size s) {
        return s == null ? "null" : s.getWidth() + "x" + s.getHeight();
    }

    private static String rect(Rect r) {
        return r == null ? "null"
                : (r.width() + "x" + r.height() + " @(" + r.left + "," + r.top + ")");
    }
}
