package com.illixion.convolution;

import org.json.JSONObject;
import java.nio.charset.StandardCharsets;

final class CoreBridge {
    static { System.loadLibrary("quest_player"); }
    private static native byte[] callBytes(byte[] input);
    static JSONObject call(JSONObject request) throws Exception {
        byte[] result = callBytes(request.toString().getBytes(StandardCharsets.UTF_8));
        if (result == null) throw new Exception("Swift core unavailable");
        JSONObject reply = new JSONObject(new String(result, StandardCharsets.UTF_8));
        if (reply.has("error")) throw new Exception(reply.getString("error"));
        return reply;
    }
}
