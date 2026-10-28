package com.tencent.mobileqq.qsec.qsecdandelionsdk;

/**
 * 探针桩：与 TIM 的 Dandelion 类同包同名、native 方法签名逐字一致
 * （TIM: private native byte[] energy(Object, Object)）。
 * 目的只有一个：让 libfekit/libQSec 的 JNI_OnLoad 里的 RegisterNatives
 * 能找到宿主类并成功绑定，然后我们直接调 fly() 看 native 在「非腾讯包名」里
 * 还愿不愿意出签名。正式业务代码绝不引用本类。
 */
public class Dandelion {
    private static final Dandelion INSTANCE = new Dandelion();
    private static boolean isInit = false;

    public static Dandelion getInstance() { return INSTANCE; }

    private native byte[] energy(Object obj, Object obj2);

    public void init() { isInit = true; }
    public boolean isInit() { return isInit; }

    public byte[] fly(String str, byte[] bArr) {
        isInit = true;
        return energy(str, bArr);
    }
}
