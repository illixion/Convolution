package com.illixion.convolution;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.text.InputType;
import android.widget.*;
import org.json.*;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private LinearLayout content;
    private TextView status;
    private String server, authorization, userID;
    private final String deviceID = UUID.randomUUID().toString();
    private boolean busy = false;
    private EditText url, username, password;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL); content.setPadding(32,24,32,24);
        ScrollView scroll = new ScrollView(this); scroll.addView(content); setContentView(scroll);
        TextView title = new TextView(this); title.setText("Convolution · Quest"); title.setTextSize(28); content.addView(title);
        url = field("Jellyfin server URL", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        url.setText(getPreferences(0).getString("server", "http://127.0.0.1:8097"));
        username = field("Username", InputType.TYPE_CLASS_TEXT);
        password = field("Password", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        Button login = new Button(this); login.setText("Sign in and browse"); login.setOnClickListener(v -> signIn()); content.addView(login);
        status = new TextView(this); content.addView(status);
        TextView controls = new TextView(this);
        controls.setText("In the player: A pauses · B returns · X recenters · right stick seeks ±10s.\nOriginal HEVC, SBS and OU play on compositor layers. Choose a capped stream for SDR H.264.\nSign-in lasts for this app session."); content.addView(controls);
        // A private, debug-only fixture file enables a USB launch without secrets in argv.
        if (BuildConfig.DEBUG) {
            try {
                java.io.File fixture = new java.io.File(getFilesDir(), "dev-launch.json");
                if (fixture.exists()) {
                    JSONObject config = new JSONObject(new String(java.nio.file.Files.readAllBytes(fixture.toPath()), java.nio.charset.StandardCharsets.UTF_8));
                    fixture.delete();
                    url.setText(config.getString("server")); username.setText(config.getString("username")); password.setText(config.getString("password"));
                    autoItemName = config.optString("playName", ""); autoSubtitleLanguage = config.optString("subtitleLanguage", ""); autoStartOver = config.optBoolean("startOver"); signIn();
                }
            } catch (Exception e) { status.setText("Invalid developer fixture"); }
        }
    }
    private String autoItemName = "", autoSubtitleLanguage = "";
    private boolean autoStartOver = false, autoPlayback = false;
    private EditText field(String hint, int input) {
        EditText field = new EditText(this); field.setHint(hint); field.setInputType(input); content.addView(field); return field;
    }
    private void signIn() {
        if (busy) return;
        server = url.getText().toString().trim();
        String name = username.getText().toString(), secret = password.getText().toString(); password.setText("");
        authorization = "MediaBrowser Client=\"Convolution\", Device=\"Quest\", DeviceId=\"" + deviceID + "\", Version=\"0.1\"";
        busy = true; status.setText("Signing in through Swift…"); android.util.Log.i("ConvolutionCore","login_started");
        worker.execute(() -> {
            try {
                JSONObject request = command("login"); request.put("username",name); request.put("password",secret);
                JSONObject session = CoreBridge.call(request);
                android.util.Log.i("ConvolutionCore","login_ok swift_jni=true");
                userID = session.getJSONObject("User").getString("Id");
                authorization += ", Token=\"" + session.getString("AccessToken") + "\"";
                JSONObject catalog = CoreBridge.call(command("catalog"));
                android.util.Log.i("ConvolutionCore","catalog_items="+catalog.getJSONArray("items").length());
                runOnUiThread(() -> { busy = false; getPreferences(0).edit().putString("server",server).apply(); showCatalog(catalog); });
            } catch (Exception e) { runOnUiThread(() -> { busy = false; status.setText(e.getMessage()); android.util.Log.w("ConvolutionCore","request_failed"); }); }
        });
    }
    private JSONObject command(String operation) throws JSONException {
        return new JSONObject().put("operation",operation).put("server",server).put("authorization",authorization).put("userID",userID);
    }
    private void showCatalog(JSONObject catalog) {
        try {
            status.setText("Swift core connected · choose a title");
            JSONArray items = catalog.getJSONArray("items");
            for (int i=0;i<items.length();i++) {
                JSONObject item = items.getJSONObject(i);
                Button button = new Button(this); button.setText(item.getString("name") + " · " + item.getString("stereo"));
                button.setOnClickListener(v -> chooseQuality(item)); content.addView(button);
                if (!autoItemName.isEmpty() && item.getString("name").contains(autoItemName)) { autoItemName = ""; autoPlayback = true; play(item,"original"); }
            }
        } catch (Exception e) { status.setText("Invalid library response"); }
    }
    private void chooseQuality(JSONObject item) {
        new android.app.AlertDialog.Builder(this).setTitle("Playback quality")
            .setItems(new String[]{"Auto", "Original", "1080p · 10 Mbps", "720p · 4 Mbps"}, (dialog, which) -> play(item,new String[]{"auto","original","mbps10","mbps4"}[which])).show();
    }
    private void play(JSONObject item, String quality) {
        if (busy) return;
        busy = true; status.setText("Preparing playback…");
        worker.execute(() -> {
            try {
                JSONObject request = command("playback").put("itemID",item.getString("id")).put("quality",quality);
                if (autoPlayback && autoStartOver) request.put("position",0);
                JSONObject plan = CoreBridge.call(request);
                plan.put("autoQuality",quality.equals("auto"));
                plan.put("server",server).put("userID",userID).put("itemID",item.getString("id"));
                runOnUiThread(() -> { busy = false;
                    if (autoPlayback) {
                        autoPlayback = false;
                        JSONArray tracks = plan.optJSONArray("subtitles");
                        if (tracks != null) for (int i=0;i<tracks.length();i++) {
                            JSONObject t = tracks.optJSONObject(i);
                            if (t.optBoolean("playable") && t.optString("language").equals(autoSubtitleLanguage)) {
                                try { plan.put("subtitleIndex",t.optInt("index")); } catch (JSONException ignored) { }
                            }
                        }
                        openPlayer(plan);
                    } else chooseSubtitles(plan);
                });
            } catch (Exception e) { runOnUiThread(() -> { busy = false; status.setText(e.getMessage()); android.util.Log.w("ConvolutionCore","request_failed"); }); }
        });
    }
    private void openPlayer(JSONObject plan) {
        startActivity(new Intent(this,PlayerActivity.class).setAction(Intent.ACTION_MAIN).addCategory("com.oculus.intent.category.VR").putExtra("plan",plan.toString()));
    }
    private void chooseSubtitles(JSONObject plan) {
        JSONArray tracks = plan.optJSONArray("subtitles");
        if (tracks == null || tracks.length() == 0) { openPlayer(plan); return; }
        java.util.ArrayList<String> labels = new java.util.ArrayList<>();
        java.util.ArrayList<JSONObject> playable = new java.util.ArrayList<>();
        labels.add("Off");
        String preferred = getPreferences(0).getString("subtitleLanguage","");
        int selected = 0;
        for (int i=0;i<tracks.length();i++) {
            JSONObject t = tracks.optJSONObject(i);
            if (t.optBoolean("playable")) {
                labels.add(t.optString("name")); playable.add(t);
                if ((!preferred.isEmpty() && preferred.equals(t.optString("language"))) || (preferred.isEmpty() && t.optBoolean("forced"))) selected = playable.size();
            }
        }
        if (playable.isEmpty()) { openPlayer(plan); return; }
        final int[] choice = {selected};
        new android.app.AlertDialog.Builder(this).setTitle("Subtitles")
            .setSingleChoiceItems(labels.toArray(new String[0]),selected,(dialog,which)->choice[0]=which)
            .setPositiveButton("Play",(dialog,which)-> {
                try {
                    JSONObject track = choice[0] == 0 ? null : playable.get(choice[0]-1);
                    plan.put("subtitleIndex",track==null ? -1 : track.optInt("index"));
                    plan.put("subtitlesOff",track==null);
                    getPreferences(0).edit().putString("subtitleLanguage",track==null ? "off" : track.optString("language")).apply();
                    openPlayer(plan);
                } catch (JSONException ignored) { }
            }).setNegativeButton("Cancel",null).show();
    }
    @Override public void onDestroy() { worker.shutdown(); super.onDestroy(); }
}
