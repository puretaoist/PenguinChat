package com.tencent.mobileqq.dt;

import android.content.Context;
import com.tencent.mobileqq.channel.ChannelProxy;
import com.tencent.mobileqq.fe.IFEKitLog;

/** 探针桩：libfekit 会向 Dtn 注册 native。 */
public class Dtn {
    private static Dtn a;
    public static Dtn a() { if (a == null) a = new Dtn(); return a; }

    public native void finitMainProcess();
    public native void initContext(Context context, String str);
    public native void initGlobalConfig(String a, String b, String c, String d, String e, String f, String g);
    public native void initLog(IFEKitLog log);
    public native void initMainProcess(Context context, ChannelProxy proxy);
    public native void initUin(String str);
}
