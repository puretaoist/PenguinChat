package com.tencent.mobileqq.channel;

import com.tencent.mobileqq.fe.CmdWhiteListChangeCallback;
import java.util.ArrayList;

/** 探针桩：libfekit 会向 ChannelManager 注册 native。 */
public class ChannelManager {
    private static ChannelManager mInstance;
    public static ChannelManager getInstance() {
        if (mInstance == null) mInstance = new ChannelManager();
        return mInstance;
    }

    private native void initReport();
    public native ArrayList<String> getCmdWhiteList();
    public native void onChannelReady();
    public native void onMsfConnected();
    public native void onNativeReceive(String str, byte[] bArr, boolean z, int i, long j);
    public native void sendMessageTest();
    public native void setChannelProxy(ChannelProxy channelProxy);
    public native void setCmdWhiteListChangeCallback(CmdWhiteListChangeCallback cb);

    public void setNativeChannel() { }
    public void init(ChannelProxy proxy) { setChannelProxy(proxy); }
}
