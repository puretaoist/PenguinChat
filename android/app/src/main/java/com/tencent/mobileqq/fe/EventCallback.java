package com.tencent.mobileqq.fe;

/** 探针桩：TIM FEKit 的事件回调接口。 */
public interface EventCallback {
    void onResult(int code, byte[] data);
}
