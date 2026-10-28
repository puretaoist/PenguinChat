package oicq.wlogin_sdk.request;
public class WtloginMsfListener implements Runnable {
    public static String CLIENT_CLASSNAME;
    public void onReceiveData(String serviceCmd, String uin, byte[] data) { }
    public void onReceiveFail(String serviceCmd, String uin, int ret) { }
    public void run() { }
    public int getRet() { return 0; }
    public byte[] getRetData() { return null; }
}
