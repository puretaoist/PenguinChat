package com.tencent.mobileqq.qsec.qseccodec;

import android.content.Context;

/** 探针桩：libfekit 的 JNI_OnLoad 会向 SecCipher 注册 native（codec 等）。 */
public class SecCipher {
    private static final SecCipher INSTANCE = new SecCipher();
    public static SecCipher getInstance() { return INSTANCE; }

    public native Object codec(Object obj, int i);

    public static class SecInfo {
        public byte[] data;
    }
    public void init(Context ctx) { }
}
