package com.tencent.mobileqq.qsec.qsecest;

import android.content.Context;

/** 探针桩：占位，保证 JNI_OnLoad 里的 FindClass 不返回 null。 */
public class QsecEst {
    public static String a(Context ctx, String a, String b) { return ""; }
}
