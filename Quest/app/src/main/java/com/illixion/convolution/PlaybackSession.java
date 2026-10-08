package com.illixion.convolution;

import android.content.Context;
import android.os.*;
import android.graphics.*;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import android.view.Surface;

import android.util.Log;
import android.widget.Toast;
import androidx.media3.common.*;
import androidx.media3.exoplayer.*;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.DefaultDataSource;
import org.json.*;
import java.util.Collections;
import java.util.concurrent.*;

/** App-scoped media session. Presentations borrow surfaces and never own the clock. */
public final class PlaybackSession {
    public interface Host {
        void picture(float aspect, int layout, boolean ready, int width, int height);
        void failed();
    }
    private static PlaybackSession current;
    public static PlaybackSession current() { return current; }
    public static PlaybackSession open(Context context, JSONObject plan) {
        if (current != null && current.plan.optString("playSessionID").equals(plan.optString("playSessionID"))) return current;
        if (current != null) current.close();
        current = new PlaybackSession(context.getApplicationContext(), plan);
        return current;
    }
    private final Context context;
    private Host host;
    /** SDK reference-space poses: position xyz, quaternion xyzw; no UI coordinates. */
    public interface SpatialPoseSink { void update(long timestampNanos, float[] listener, float[] screen); }
    private volatile SpatialPoseSink spatialPoseSink;
    public void setSpatialPoseSink(SpatialPoseSink sink) { spatialPoseSink = sink; }
    public void spatialPose(long timestamp, float[] listener, float[] screen) {
        SpatialPoseSink sink = spatialPoseSink; if (sink != null) sink.update(timestamp,listener,screen);
    }
    private float aspect = 16f/9f;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private JSONObject plan;
    private ExoPlayer player;
    private Surface subtitles, videoSurface;
    private JSONArray cues = new JSONArray();
    private String captionText = "";
    private String topCaptionText = "";
    private boolean active = false, intendedPlay = true, stopped = false, firstFrame = false;
    private int layout;
    private long lastReport = 0, lastStallCheck = 0;
    private boolean changingQuality = false;
    private volatile JSONObject skipSuggestion;
    private volatile boolean skipCheckPending = false;
    private long lastSkipCheck = 0;
    private PlaybackSession(Context context, JSONObject plan) {
        this.context = context; this.plan = plan;
        String format = plan.optString("stereo");
        layout = format.equals("HalfSideBySide") ? 1 : format.equals("FullSideBySide") ? 2 : format.equals("HalfTopAndBottom") ? 3 : format.equals("FullTopAndBottom") ? 4 : 0;
    }
    public void attach(Host owner, Surface video, Surface captions) {
        onMainSync(() -> {
            if (host != null && host != owner) suspendVideo();
            host = owner; videoSurface = video; subtitles = captions;
            if (player != null) { player.setVideoSurface(videoSurface); updatePicture(player.getVideoSize()); }
        });
    }
    public void detach(Host owner) {
        onMainSync(() -> {
            if (host != owner) return;
            suspendVideo(); host = null; videoSurface = null; subtitles = null;
        });
    }
    public String title() { return plan.optString("name","Convolution"); }
    public int packing() { return layout; }
    public double position() { return player == null ? plan.optDouble("position") : player.getCurrentPosition()/1000.0; }
    public double duration() { return player == null || player.getDuration() == C.TIME_UNSET ? 0 : player.getDuration()/1000.0; }
    public boolean paused() { return !intendedPlay; }
    public String bottomCaption() { return captionText; }
    public String topCaption() { return topCaptionText; }
    public float aspect() { return aspect; }
    public int audioSessionID() { return player == null ? C.AUDIO_SESSION_ID_UNSET : player.getAudioSessionId(); }
    public int videoWidth() { return plan.optInt("width",1920); }
    public int videoHeight() { return plan.optInt("height",1080); }
    private void createDecoder() {
            if (player != null || videoSurface == null || stopped) return;
            drawCaptions("", "");
            DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
                .setDefaultRequestProperties(Collections.singletonMap("Authorization",plan.optString("authorization")))
                .setConnectTimeoutMs(20000).setReadTimeoutMs(20000);
            player = new ExoPlayer.Builder(context).setMediaSourceFactory(
                new DefaultMediaSourceFactory(new DefaultDataSource.Factory(context,http))).build();
            player.setVideoSurface(videoSurface);
            player.setAudioAttributes(new AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),true);
            // Captions are fetched/parsed by the Swift core and placed on their own XR layer.
            player.setTrackSelectionParameters(player.getTrackSelectionParameters().buildUpon().setTrackTypeDisabled(C.TRACK_TYPE_TEXT,true).build());
            player.addListener(new Player.Listener() {
                @Override public void onRenderedFirstFrame() {
                    firstFrame = true;
                    updatePicture(player.getVideoSize());
                    Log.i("ConvolutionMedia","first_frame mediaCodec_surface=true");
                }
                @Override public void onVideoSizeChanged(VideoSize size) { updatePicture(size); }
                @Override public void onPlayerError(PlaybackException error) {
                    Log.e("ConvolutionMedia","playback_error code=" + error.errorCode);
                    Toast.makeText(context,"Playback failed. Try a capped stream for a compatible format.",Toast.LENGTH_LONG).show();
                    if (host != null) host.failed();
                }
                @Override public void onPlaybackStateChanged(int state) {
                    Log.i("ConvolutionMedia","playback_state=" + state);
                    if (state == Player.STATE_ENDED) { intendedPlay = false; report("stopped"); }
                }
            });
            player.addAnalyticsListener(new AnalyticsListener() {
                @Override public void onVideoDecoderInitialized(EventTime time, String name, long timestamp, long duration) {
                    // Codec name is a system-defined capability; never log a URL/title/token.
                    Log.i("ConvolutionMedia","decoder=" + name + " init_ms=" + duration);
                }
                @Override public void onDroppedVideoFrames(EventTime time, int frames, long elapsed) {
                    Log.i("ConvolutionMedia","dropped_frames=" + frames + " interval_ms=" + elapsed);
                }
            });
            player.setMediaItem(MediaItem.fromUri(plan.optString("url")));
            player.seekTo((long)(plan.optDouble("position",0)*1000));
            player.prepare(); player.setPlayWhenReady(active && intendedPlay);
            report("started");
            loadSubtitles(); main.post(tick);
    }
    private void updatePicture(VideoSize size) {
        // Half packing already declares the squeeze. Some encoders also mark
        // that squeeze as SAR (the fixture is 2:1); applying both doubles it.
        float pixelRatio = (layout == 1 || layout == 3) ? 1 : size.pixelWidthHeightRatio;
        aspect = size.height > 0 ? size.width * pixelRatio / size.height : (float)videoWidth()/videoHeight();
        if (layout == 2) aspect /= 2; if (layout == 4) aspect *= 2;
        Log.i("ConvolutionMedia","picture_aspect="+aspect+" packing="+layout+" pixel_ratio="+size.pixelWidthHeightRatio);
        if (host != null) host.picture(aspect,layout,firstFrame,size.width,size.height);
    }
    private void loadSubtitles() {
        if (plan.optBoolean("subtitlesOff")) return;
        JSONArray tracks = plan.optJSONArray("subtitles");
        int index = plan.optInt("subtitleIndex",-1);
        if (index < 0 && tracks != null) for (int i=0;i<tracks.length();i++) {
            JSONObject track = tracks.optJSONObject(i);
            if (track.optBoolean("forced") && track.optBoolean("playable")) { index = track.optInt("index",-1); break; }
        }
        if (index < 0) return;
        final int chosen = index;
        worker.execute(() -> {
            try {
                JSONObject request = command("subtitles").put("trackIndex",chosen);
                JSONArray loaded = CoreBridge.call(request).getJSONArray("cues");
                main.post(() -> { cues = loaded; Log.i("ConvolutionMedia","subtitle_cues="+loaded.length()); });
            } catch (Exception e) { main.post(() -> Toast.makeText(context,"Subtitles unavailable",Toast.LENGTH_SHORT).show()); }
        });
    }
    private JSONObject command(String operation) throws JSONException {
        return new JSONObject().put("operation",operation).put("server",plan.getString("server"))
            .put("authorization",plan.getString("authorization")).put("userID",plan.getString("userID"))
            .put("itemID",plan.getString("itemID")).put("sourceID",plan.getString("sourceID"))
            .put("playSessionID",plan.getString("playSessionID"));
    }
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (player == null || stopped) return;
            double time = player.getCurrentPosition()/1000.0 - plan.optDouble("subtitleDelay",0);
            StringBuilder text = new StringBuilder();
            StringBuilder top = new StringBuilder();
            for (int i=0;i<cues.length();i++) {
                JSONObject cue = cues.optJSONObject(i);
                if (cue.optDouble("start") <= time && cue.optDouble("end") > time) {
                    StringBuilder group = cue.optBoolean("top") ? top : text;
                    if (group.length()>0) group.append('\n'); group.append(cue.optString("text"));
                }
            }
            if (!captionText.equals(text.toString()) || !topCaptionText.equals(top.toString())) {
                captionText = text.toString(); topCaptionText = top.toString(); if (active) drawCaptions(captionText,topCaptionText);
            }
            long now = SystemClock.elapsedRealtime();
            if (plan.optBoolean("autoQuality") && now-lastStallCheck > 1000 && !changingQuality) {
                checkStall(); lastStallCheck = now;
            }
            if (now-lastReport>10000) {
                report("progress"); lastReport = now;
                Log.i("ConvolutionMedia","position_ms="+player.getCurrentPosition()+" buffered_ms="+player.getTotalBufferedDuration()+" playing="+player.isPlaying());
            }
            if (now-lastSkipCheck>500 && !skipCheckPending && plan.optJSONArray("segments")!=null) {
                lastSkipCheck=now; skipCheckPending=true;
                try {
                    JSONObject request=command("skip").put("segments",plan.getJSONArray("segments"))
                        .put("currentTime",player.getCurrentPosition()/1000.0).put("duration",duration())
                        .put("controlsVisible",true);
                    worker.execute(() -> {
                        try { JSONObject result=CoreBridge.call(request).optJSONObject("segment"); skipSuggestion=result; }
                        catch(Exception ignored) { skipSuggestion=null; }
                        finally { skipCheckPending=false; }
                    });
                } catch(JSONException ignored) { skipCheckPending=false; }
            }
            main.postDelayed(this,50);
        }
    };
    private void checkStall() {
        if (player == null || !active || !intendedPlay) return;
        try {
            JSONObject request = command("stall").put("waiting",player.getPlaybackState()==Player.STATE_BUFFERING)
                .put("hasFrame",firstFrame).put("paused",!intendedPlay).put("quality",plan.optString("quality","auto"))
                .put("sourceBitrate",plan.optInt("bitrate"));
            worker.execute(() -> {
                try {
                    String next = CoreBridge.call(request).optString("next");
                    if (!next.isEmpty()) main.post(() -> switchQuality(next));
                } catch (Exception ignored) { }
            });
        } catch (JSONException ignored) { }
    }
    private void switchQuality(String quality) {
        if (player == null || stopped || changingQuality) return;
        changingQuality = true;
        final long position = player.getCurrentPosition();
        try {
            JSONObject request = command("playback").put("position",position/1000.0).put("quality",quality);
            worker.execute(() -> {
                try {
                    JSONObject next = CoreBridge.call(request);
                    main.post(() -> {
                        changingQuality = false;
                        if (player == null || stopped) return;
                        try {
                            // Keep the original reporting session; a renderer change never resets watch state.
                            plan.put("quality",quality); plan.put("url",next.getString("url"));
                            firstFrame = false;
                            player.setMediaItem(MediaItem.fromUri(next.getString("url")),position);
                            player.prepare(); player.setPlayWhenReady(active && intendedPlay);
                            report("seekGrace");
                            Toast.makeText(context,"Stream quality lowered to keep playback moving",Toast.LENGTH_SHORT).show();
                            Log.i("ConvolutionMedia","quality_step="+quality+" position_ms="+position);
                        } catch (JSONException ignored) { }
                    });
                } catch (Exception e) { main.post(() -> changingQuality = false); }
            });
        } catch (JSONException ignored) { changingQuality = false; }
    }
    private void drawCaptions(String bottom, String top) {
        if (subtitles == null || !subtitles.isValid()) return;
        Canvas canvas = null;
        try {
            canvas = subtitles.lockCanvas(null); canvas.drawColor(Color.TRANSPARENT,PorterDuff.Mode.CLEAR);
            TextPaint paint = new TextPaint(Paint.ANTI_ALIAS_FLAG); paint.setColor(Color.WHITE); paint.setTextSize(32);
            paint.setTypeface(Typeface.create(Typeface.SANS_SERIF,Typeface.BOLD)); paint.setShadowLayer(4,0,2,Color.BLACK);
            drawTextGroup(canvas,paint,bottom,false);
            drawTextGroup(canvas,paint,top,true);
        } catch (RuntimeException e) { Log.e("ConvolutionMedia","subtitle_surface_failed"); }
        finally { if (canvas != null) subtitles.unlockCanvasAndPost(canvas); }
    }
    private void drawTextGroup(Canvas canvas, TextPaint paint, String text, boolean top) {
        if (text.isEmpty()) return;
        StaticLayout lines = StaticLayout.Builder.obtain(text,0,text.length(),paint,1152)
            .setAlignment(Layout.Alignment.ALIGN_CENTER).setIncludePad(false).build();
        canvas.save(); canvas.translate(64,top ? 40 : Math.max(40,680-lines.getHeight()));
        lines.draw(canvas); canvas.restore();
    }
    private void report(String operation) {
        if (player == null) return;
        if (plan.optBoolean("offline")) {
            context.getSharedPreferences("library-downloads",Context.MODE_PRIVATE).edit()
                .putLong("offline_position_"+plan.optString("itemID"),player.getCurrentPosition()).apply();
            return;
        }
        try {
            JSONObject request = command(operation).put("position",player.getCurrentPosition()/1000.0).put("paused",!player.isPlaying());
            worker.execute(() -> { try { CoreBridge.call(request); } catch (Exception e) { Log.w("ConvolutionMedia","watch_report_failed"); } });
        } catch (JSONException ignored) { }
    }
    public void toggleVideo() { main.post(() -> { if (player != null) { if (player.getPlaybackState()==Player.STATE_ENDED) { player.seekTo(0); intendedPlay = true; } else intendedPlay = !intendedPlay; player.setPlayWhenReady(active && intendedPlay); report("seekGrace"); report("progress"); } }); }
    public void seekVideo(int seconds) { main.post(() -> { if (player != null) { player.seekTo(Math.max(0,player.getCurrentPosition()+seconds*1000L)); report("seekGrace"); report("progress"); } }); }
    public void seekTo(double seconds) { main.post(() -> { if (player != null) { player.seekTo(Math.max(0,(long)(seconds*1000))); report("seekGrace"); report("progress"); } }); }
    public JSONObject skipSuggestion() { return skipSuggestion; }
    public void skipSegment() {
        JSONObject suggestion=skipSuggestion;
        if(suggestion==null) return;
        seekTo(suggestion.optDouble("target",position()));
        skipSuggestion=null;
    }
    public void suspendVideo() { onMainSync(() -> {
        active = false;
        main.removeCallbacks(tick);
        if (player != null) { player.pause(); player.clearVideoSurface(); report("progress"); }
    }); }
    public void resumeVideo() { main.post(() -> {
        active = true; createDecoder();
        if (player != null) { player.setVideoSurface(videoSurface); player.setPlayWhenReady(intendedPlay); drawCaptions(captionText,topCaptionText); }
        main.removeCallbacks(tick); main.post(tick);
    }); }
    public void close() { onMainSync(this::releaseVideo); worker.shutdown(); if (current == this) current = null; }
    private void onMainSync(Runnable action) {
        if (Looper.myLooper() == Looper.getMainLooper()) { action.run(); return; }
        CountDownLatch done = new CountDownLatch(1);
        main.post(() -> { try { action.run(); } finally { done.countDown(); } });
        try { done.await(3,TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }
    private void releaseVideo() {
        if (stopped) return;
        stopped = true; main.removeCallbacks(tick);
        if (player != null) { report("stopped"); player.clearVideoSurface(); player.release(); player = null; }
        subtitles = null; videoSurface = null; host = null;
    }
}
