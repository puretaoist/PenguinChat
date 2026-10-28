package com.tencent.mobileqq.qsec.qsecprotocol;

import android.content.Context;

/** 探针桩：TIM 的 ByteData（libfekit 的 JNI_OnLoad 会 FindClass 它）。 */
public class ByteData {
    private static final ByteData INSTANCE = new ByteData();
    private Context mContext;

    public static ByteData getInstance() { return INSTANCE; }
    public void init(Context context) { this.mContext = context; }

    private native byte[] getByte(Context context, Object obj);

    public byte[] probeGetByte(Context ctx, Object o) { return getByte(ctx, o); }
}
