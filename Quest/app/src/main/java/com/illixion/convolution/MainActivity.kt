package com.illixion.convolution

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Authentication/catalog state survives switching presentations, but not process death. */
private object LibrarySession {
    var server = ""
    var authorization = ""
    var userID = ""
    var catalog by mutableStateOf<List<JSONObject>>(emptyList())
}

class MainActivity : ComponentActivity() {
    private var status by mutableStateOf("")
    private var busy by mutableStateOf(false)
    private var selected by mutableStateOf<JSONObject?>(null)
    private var subtitles by mutableStateOf<JSONObject?>(null)
    private var fixture: JSONObject? = null
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val prefs = getPreferences(0)
        if (LibrarySession.server.isEmpty()) LibrarySession.server=prefs.getString("server","http://127.0.0.1:8097")!!
        if (BuildConfig.DEBUG) {
            val file = java.io.File(filesDir,"dev-launch.json")
            if(file.exists()) {
                try { fixture=JSONObject(file.readText()); file.delete() } catch (_: Exception) { file.delete(); status="Invalid developer fixture" }
            }
        }
        setContent { MaterialTheme { Surface(Modifier.fillMaxSize()) {
            var server by remember { mutableStateOf(LibrarySession.server) }
            var username by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
            Column(Modifier.fillMaxSize().padding(24.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                Text("Convolution",style=MaterialTheme.typography.headlineLarge)
                if(LibrarySession.catalog.isEmpty()) {
                    OutlinedTextField(server,{server=it},label={Text("Jellyfin server URL")},modifier=Modifier.fillMaxWidth())
                    OutlinedTextField(username,{username=it},label={Text("Username")},modifier=Modifier.fillMaxWidth())
                    OutlinedTextField(password,{password=it},label={Text("Password")},visualTransformation=PasswordVisualTransformation(),modifier=Modifier.fillMaxWidth())
                    Button(enabled=!busy,onClick={val secret=password; password=""; signIn(server,username,secret)}) {Text("Sign in")}
                } else {
                    Row(horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                        PlaybackSession.current()?.let { session -> Button(onClick={openExisting()}) { Text("Resume ${session.title()}") } }
                        OutlinedButton(onClick={PlaybackSession.current()?.close(); LibrarySession.catalog=emptyList(); LibrarySession.authorization=""; LibrarySession.userID=""}) {Text("Sign out")}
                    }
                    LazyColumn(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                        items(LibrarySession.catalog,key={it.getString("id")}) { item ->
                            OutlinedButton(enabled=!busy,onClick={selected=item},modifier=Modifier.fillMaxWidth()) { Text(item.optString("name")) }
                        }
                    }
                }
                if(busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(status)
                Text("Play in a window alongside your other apps, or switch to a movable screen in spatial view.")
            }
            selected?.let { item -> AlertDialog(onDismissRequest={selected=null},title={Text("Playback quality")},text={Column {
                listOf("Auto" to "auto","Original" to "original","1080p · 10 Mbps" to "mbps10","720p · 4 Mbps" to "mbps4").forEach { (label,quality) ->
                    TextButton(onClick={selected=null; prepare(item,quality)}) {Text(label)}
                }
            }},confirmButton={},dismissButton={TextButton(onClick={selected=null}) {Text("Cancel")}}) }
            subtitles?.let { plan ->
                val tracks=plan.optJSONArray("subtitles").objects().filter {it.optBoolean("playable")}
                val preference=getPreferences(0).getString("subtitleLanguage","")
                val preferred=tracks.firstOrNull {it.optString("language")==preference} ?: tracks.firstOrNull {preference.isNullOrEmpty() && it.optBoolean("forced")}
                AlertDialog(onDismissRequest={subtitles=null},title={Text("Subtitles")},text={Column {
                    TextButton(onClick={launchPlan(plan,-1)}) {Text("Off")}
                    tracks.forEach { track -> TextButton(onClick={launchPlan(plan,track.optInt("index"))}) {Text(track.optString("name")+if(track==preferred) " · Preferred" else "")} }
                }},confirmButton={},dismissButton={TextButton(onClick={subtitles=null}) {Text("Cancel")}})
            }
        } } }
        fixture?.let { signIn(it.getString("server"),it.getString("username"),it.getString("password")) }
    }
    private fun command(operation: String)=JSONObject().put("operation",operation).put("server",LibrarySession.server).put("authorization",LibrarySession.authorization).put("userID",LibrarySession.userID)
    private fun signIn(server: String,name: String,secret: String) {
        if(busy) return; busy=true; status="Signing in…"
        LibrarySession.server=server.trim()
        val prefs=getPreferences(0)
        val device=prefs.getString("deviceID",null) ?: UUID.randomUUID().toString().also {prefs.edit().putString("deviceID",it).apply()}
        LibrarySession.authorization="MediaBrowser Client=\"Convolution\", Device=\"Quest\", DeviceId=\"$device\", Version=\"0.2\""
        lifecycleScope.launch {
            try {
                val catalog=withContext(Dispatchers.IO) {
                    val login=CoreBridge.call(command("login").put("username",name).put("password",secret))
                    LibrarySession.userID=login.getJSONObject("User").getString("Id")
                    LibrarySession.authorization+=", Token=\"${login.getString("AccessToken")}\""
                    CoreBridge.call(command("catalog")).getJSONArray("items").objects()
                }
                LibrarySession.catalog=catalog; busy=false; status="Choose a title"
                prefs.edit().putString("server",LibrarySession.server).apply()
                Log.i("ConvolutionCore","login_ok catalog_items=${catalog.size}")
                fixture?.optString("playName")?.takeIf {it.isNotEmpty()}?.let {name -> catalog.firstOrNull {it.optString("name").contains(name)}?.let {prepare(it,"original")} }
            } catch (e: Exception) { busy=false; status=e.message ?: "Sign-in failed" }
        }
    }
    private fun prepare(item: JSONObject,quality: String) {
        if(busy) return; busy=true; status="Preparing playback…"
        lifecycleScope.launch {
            try {
                val request=command("playback").put("itemID",item.getString("id")).put("quality",quality)
                if(fixture?.optBoolean("startOver")==true) request.put("position",0)
                val plan=withContext(Dispatchers.IO) {CoreBridge.call(request)}
                    .put("autoQuality",quality=="auto").put("server",LibrarySession.server).put("userID",LibrarySession.userID).put("itemID",item.getString("id"))
                busy=false
                val developer=fixture
                if(developer!=null) {
                    val track=plan.optJSONArray("subtitles").objects().firstOrNull {it.optBoolean("playable") && it.optString("language")==developer.optString("subtitleLanguage")}
                    launchPlan(plan,track?.optInt("index") ?: -1)
                } else if(plan.optJSONArray("subtitles").objects().any {it.optBoolean("playable")}) subtitles=plan else launchPlan(plan,-1)
            } catch(e: Exception) {busy=false; status=e.message ?: "Playback unavailable"}
        }
    }
    private fun launchPlan(plan: JSONObject,index: Int) {
        subtitles=null; plan.put("subtitleIndex",index).put("subtitlesOff",index<0)
        val language=plan.optJSONArray("subtitles").objects().firstOrNull {it.optInt("index")==index}?.optString("language") ?: "off"
        getPreferences(0).edit().putString("subtitleLanguage",language).apply()
        PlaybackSession.open(this,plan)
        val mode=fixture?.optString("presentation"); fixture=null
        val type=when(mode) {"spatial" -> SpatialPlayerActivity::class.java; "native" -> PlayerActivity::class.java; else -> HomePlayerActivity::class.java}
        val intent=Intent(this,type).setAction(Intent.ACTION_MAIN)
        if(type!=HomePlayerActivity::class.java) intent.addCategory("com.oculus.intent.category.VR")
        startActivity(intent)
    }
    private fun openExisting() {startActivity(Intent(this,HomePlayerActivity::class.java).setAction(Intent.ACTION_MAIN))}
}
private fun JSONArray?.objects(): List<JSONObject> = if(this==null) emptyList() else (0 until length()).mapNotNull {optJSONObject(it)}
