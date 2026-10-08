package com.illixion.convolution;

import android.app.NativeActivity;
import android.os.Bundle;
import android.view.Surface;
import android.view.WindowManager;
import org.json.JSONObject;

/** OpenXR presentation adapter; playback survives destruction of this activity. */
public final class PlayerActivity extends NativeActivity implements PlaybackSession.Host {
    static { System.loadLibrary("quest_player"); }
    private PlaybackSession session;
    private static native void setPicture(float aspect, int layout, boolean ready, int width, int height);
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        try {
            String plan = getIntent().getStringExtra("plan");
            session = plan == null ? PlaybackSession.current() : PlaybackSession.open(this,new JSONObject(plan));
            if (session == null) finish();
        } catch (Exception e) { finish(); }
    }
    public int videoWidth() { return session.videoWidth(); }
    public int videoHeight() { return session.videoHeight(); }
    public void startVideo(Surface video, Surface captions) { session.attach(this,video,captions); }
    public void toggleVideo() { session.toggleVideo(); }
    public void seekVideo(int seconds) { session.seekVideo(seconds); }
    public void suspendVideo() { session.suspendVideo(); }
    public void resumeVideo() { session.resumeVideo(); }
    public void leavePlayer() { runOnUiThread(this::finish); }
    public void stopVideo() { if (session != null) session.detach(this); }
    @Override public void picture(float aspect, int layout, boolean ready, int width, int height) { setPicture(aspect,layout,ready,width,height); }
    @Override public void failed() { leavePlayer(); }
    @Override public void onDestroy() { stopVideo(); super.onDestroy(); }
}
