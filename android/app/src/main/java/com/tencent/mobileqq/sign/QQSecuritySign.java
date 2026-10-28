package com.tencent.mobileqq.sign;

import com.tencent.mobileqq.fe.EventCallback;
import com.tencent.mobileqq.qsec.qsecurity.QSec;

/** 探针桩：与 TIM QQSecuritySign 的 native 声明逐字一致（签名见 tim 反编译 sign/QQSecuritySign.java）。 */
public class QQSecuritySign {
    private static QQSecuritySign sInstance;
    private String mExtra;

    public static synchronized QQSecuritySign getInstance() {
        if (sInstance == null) sInstance = new QQSecuritySign();
        return sInstance;
    }

    public static class SignResult {
        public byte[] extra;
        public byte[] sign;
        public byte[] token;
    }

    private native SignResult getSign(QSec qSec, String str, String str2, byte[] bArr, byte[] bArr2, String str3);
    public native void dispatchEvent(String str, String str2, EventCallback cb);
    public native void dispatchEventPB(String str, String str2, byte[] bArr, EventCallback cb);
    public native void initSafeMode(boolean z);
    public native void notifyCamera(String a, String b, String c, String d, String e, String f, EventCallback cb);
    public native void notifyFaceDetect(String a, String b, String c, EventCallback cb);
    public native void requestToken();
    public native void safeUiReport(String a, String b, String c, EventCallback cb);

    public void init(String extra) { this.mExtra = extra; }

    public SignResult getSign(QSec qSec, String str, byte[] bArr, byte[] bArr2, String str2) {
        return getSign(qSec, mExtra == null ? "" : mExtra, str, bArr, bArr2, str2);
    }
}
