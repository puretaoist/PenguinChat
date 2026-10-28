package com.tencent.qimei.uin;

import android.content.Context;

/**
 * 一次性探针桩类：只为让 TIM 的 libqimei.so 的 JNI_OnLoad 能 RegisterNatives 成功。
 * 方法名/签名与 TIM 反编译 com.tencent.qimei.uin.U 完全一致（私有 native 声明部分）。
 * 正常业务代码不引用本类。
 */
public final class U {
    private U() {}

    private static volatile boolean loaded = false;

    public static synchronized boolean ensureLoaded() {
        if (loaded) return true;
        try {
            System.loadLibrary("qimei");
            loaded = true;
        } catch (Throwable t) {
            t.printStackTrace();
        }
        return loaded;
    }

    private static native byte[] a(int i, byte[] bArr, byte[] bArr2, byte[] bArr3);
    private static native boolean b();
    private static native byte[] d(String str);
    private static native byte e(String str, String str2);
    private static native String m(int i);
    private static native void n(Context context, String str, Object[] objArr);
    private static native String o();
    private static native String p();
    private static native String r(boolean z, int i, int i2, String str, int i3, String[] strArr, String str2);
    private static native byte[] r4(byte[] bArr, int i, byte[] bArr2, int i2);
    private static native String tvc();
    private static native String tvd();
    private static native String tvm(String str);
    private static native String tvs();
    private static native String u();
    private static native boolean w(String str);
    private static native String x(String str);
    private static native String z(Context context);
    private static native String z2(Context context, int i);

    // ---- 探针用 public 包装 ----
    public static void probeInit(Context c, String appkey, Object[] cfg) { n(c, appkey, cfg); }
    public static String probeZ2(Context c, int sdk) { return z2(c, sdk); }
    public static String probeZ(Context c) { return z(c); }
    public static String probeO() { return o(); }
    public static String probeP() { return p(); }
    public static String probeU() { return u(); }
    public static String probeM(int i) { return m(i); }
    public static String probeX(String s) { return x(s); }
    public static String probeTvc() { return tvc(); }
    public static String probeTvd() { return tvd(); }
    public static String probeTvs() { return tvs(); }
    public static String probeTvm(String s) { return tvm(s); }
    public static byte[] probeD(String s) { return d(s); }
    public static boolean probeE() { return b(); }
    public static boolean probeW(String s) { return w(s); }
}
