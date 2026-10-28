package com.tencent.mobileqq.qsec.qsecurity;

import android.content.Context;

/** 探针桩：与 TIM QSec 的同名方法/native 声明一一对应，供 libfekit 的 RegisterNatives 绑定。 */
public class QSec {
    private static final QSec INSTANCE = new QSec();
    public static QSec getInstance() { return INSTANCE; }

    private native int doReport(String str, String str2, String str3, String str4);
    private native int doSomething(Context context, int i);
    private native byte[] getXwDebugID(String str);
    private native byte[] getFeKitAttach(Context context, String str, String str2, String str3);

    public int probeReport(String a, String b, String c, String d) { return doReport(a, b, c, d); }
    public int probeDoSomething(Context ctx, int i) { return doSomething(ctx, i); }
    public byte[] probeXwDebugId(String uin) { return getXwDebugID(uin); }
    public byte[] probeFeKitAttach(Context ctx, String uin, String mod, String sub) { return getFeKitAttach(ctx, uin, mod, sub); }

    // 以下方法没有 native 实现，只是让 native 侧的 GetMethodID 找得到
    public void updateO3DID(String str) { }
    public void updateODID(String str) { }
    public void updateUserID(String str) { }
    public void initSign() { }
    public String getEstInfo() { return ""; }
    public String getEstInfo(Context ctx, String s) { return ""; }
    public byte[] getXpsInfo() { return new byte[0]; }
    public int execTasks(Context ctx, int i) { return 0; }
    public boolean detectMethod(String a, String b) { return false; }
    public void init(Context c, String a, String b, String d, String e, String f) { }
}
