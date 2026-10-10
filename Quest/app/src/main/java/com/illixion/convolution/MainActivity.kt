package com.illixion.convolution

import android.content.Intent
import android.app.DownloadManager
import android.net.Uri
import android.os.Environment
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
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
import metavrx.layout.compose.SpatialScene
import metavrx.layout.compose.LocalSpatialSupported
import metavrx.layout.window.compose.SpatialWindow
import metavrx.layout.window.compose.layout.WindowModifier
import metavrx.layout.window.compose.layout.size
import metavrx.layout.window.compose.state.WindowFallback

/** Authentication/catalog state survives switching presentations, but not process death. */
internal object LibrarySession {
    var server = ""
    var authorization = ""
    var userID = ""
    var catalog by mutableStateOf<List<JSONObject>>(emptyList())
    var searchResults by mutableStateOf<List<JSONObject>>(emptyList())
    var homeShelves by mutableStateOf<List<JSONObject>>(emptyList())
    var nextCatalogIndex by mutableIntStateOf(-1)
    var nextSearchIndex by mutableIntStateOf(-1)
}

class MainActivity : ComponentActivity() {
    private var status by mutableStateOf("")
    private var busy by mutableStateOf(false)
    private var selected by mutableStateOf<JSONObject?>(null)
    private var qualityTarget by mutableStateOf<JSONObject?>(null)
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
        setContent {
          var settingsOpen by remember { mutableStateOf(false) }
          var server by remember { mutableStateOf(LibrarySession.server) }
          var username by remember { mutableStateOf("") }; var password by remember { mutableStateOf("") }
          SpatialScene(theme = { content -> ConvolutionTheme(content) }) {
            val layoutSupported = LocalSpatialSupported.current
            LaunchedEffect(layoutSupported) { Log.i("ConvolutionLayout", "spatial_windows_supported=$layoutSupported") }
            if (LibrarySession.authorization.isEmpty()) {
                SignInPanel(server, { server = it }, username, { username = it }, password, { password = it }, busy, status) {
                    val secret = password; password = ""; signIn(server, username, secret)
                }
            } else {
                LibraryBrowser(
                    items = LibrarySession.catalog, selected = selected, status = status, busy = busy,
                    shelves = LibrarySession.homeShelves,
                    searchItems = LibrarySession.searchResults,
                    onSelect = { selected = it }, onBack = { selected = null }, onPlay = { item, quality ->
                        if (quality == "choose") qualityTarget = item else prepare(item, quality)
                    },
                    onLoadMore = { searchMode -> loadMore(searchMode) },
                    onSearch = ::search,
                    onStateChange = ::changeState,
                    onDownload = ::downloadForOffline,
                    onSignOut = { signOut(); settingsOpen = false },
                    onOpenSettings = { settingsOpen = true },
                    onOpenPlayer = ::openExisting,
                )
            }
            if (settingsOpen) SpatialWindow(
                key = "convolution-settings",
                modifier = WindowModifier.size(440.dp, 560.dp),
                fallbackStrategy = WindowFallback.Inline,
            ) {
                SpatialSettingsPanel(onClose = { settingsOpen = false }, onSignOut = { signOut(); settingsOpen = false }, spatialWindowsSupported = layoutSupported)
            }
            subtitles?.let { plan ->
                val tracks=plan.optJSONArray("subtitles").objects().filter {it.optBoolean("playable")}
                val preference=getPreferences(0).getString("subtitleLanguage","")
                val preferred=tracks.firstOrNull {it.optString("language")==preference} ?: tracks.firstOrNull {preference.isNullOrEmpty() && it.optBoolean("forced")}
                AlertDialog(onDismissRequest={subtitles=null},title={Text("Subtitles")},text={Column {
                    TextButton(onClick={launchPlan(plan,-1)}) {Text("Off")}
                    tracks.forEach { track -> TextButton(onClick={launchPlan(plan,track.optInt("index"))}) {Text(track.optString("name")+if(track==preferred) " · Preferred" else "")} }
                }},confirmButton={},dismissButton={TextButton(onClick={subtitles=null}) {Text("Cancel")}})
            }
            qualityTarget?.let { item -> AlertDialog(
                onDismissRequest = { qualityTarget = null }, title = { Text("Playback quality") },
                text = { Column {
                listOf("Auto" to "auto", "Always Direct Play" to "original", "4K · 40 Mbps" to "mbps40", "1440p · 30 Mbps" to "mbps30", "1080p · 20 Mbps" to "mbps20", "1080p · 10 Mbps" to "mbps10", "720p · 4 Mbps" to "mbps4", "480p · 1.5 Mbps" to "mbps1_5").forEach { (label, quality) ->
                        TextButton(onClick = { qualityTarget = null; prepare(item, quality) }) { Text(label) }
                    }
                } }, confirmButton = {}, dismissButton = { TextButton(onClick = { qualityTarget = null }) { Text("Cancel") } }
            ) }
          }
        }
        fixture?.let { signIn(it.getString("server"),it.getString("username"),it.getString("password")) }
    }
    private fun signOut() {
        PlaybackSession.current()?.close()
        selected = null; qualityTarget = null
        LibrarySession.catalog = emptyList(); LibrarySession.authorization = ""; LibrarySession.userID = ""
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
                    val page = CoreBridge.call(command("catalog").put("startIndex",0).put("limit",40))
                    val home = CoreBridge.call(command("home"))
                    LibrarySession.nextCatalogIndex=page.optInt("nextStartIndex", -1)
                    LibrarySession.homeShelves=home.getJSONArray("shelves").objects()
                    syncOfflineProgress()
                    page.getJSONArray("items").objects().onEach(::annotateDownloadState)
                }
                LibrarySession.catalog=catalog; busy=false; status="Choose a title"
                prefs.edit().putString("server",LibrarySession.server).apply()
                Log.i("ConvolutionCore","login_ok catalog_items=${catalog.size}")
                fixture?.optString("playName")?.takeIf {it.isNotEmpty()}?.let {name -> catalog.firstOrNull {it.optString("name").contains(name)}?.let {prepare(it,"original")} }
            } catch (e: Exception) { busy=false; status=e.message ?: "Sign-in failed" }
        }
    }
    private fun loadMore(searchMode:Boolean) {
        val start=if(searchMode) LibrarySession.nextSearchIndex else LibrarySession.nextCatalogIndex
        if(busy || start<0) return
        busy=true
        lifecycleScope.launch {
            try {
                val request=if(searchMode) command("browse").put("text",searchTextSaved).put("startIndex",start).put("limit",40)
                    else command("catalog").put("startIndex",start).put("limit",40)
                val page=withContext(Dispatchers.IO) { CoreBridge.call(request) }
                val incoming=page.getJSONArray("items").objects()
                incoming.forEach(::annotateDownloadState)
                val source=if(searchMode) LibrarySession.searchResults else LibrarySession.catalog
                val known=source.mapTo(HashSet()) {it.optString("id")}
                val combined=source+incoming.filter {known.add(it.optString("id"))}
                if(searchMode) LibrarySession.searchResults=combined else LibrarySession.catalog=combined
                if(searchMode) LibrarySession.nextSearchIndex=page.optInt("nextStartIndex",-1)
                else LibrarySession.nextCatalogIndex=page.optInt("nextStartIndex", -1)
                status="Loaded ${combined.size} of ${page.optInt("totalCount",combined.size)} titles"
            } catch(e:Exception) {status=e.message ?: "Could not load more titles"}
            busy=false
        }
    }
    private var searchTextSaved=""
    private fun search(term:String) {
        if(busy) return
        busy=true
        lifecycleScope.launch {
            try {
                val page=withContext(Dispatchers.IO) {CoreBridge.call(command("browse").put("text",term).put("startIndex",0).put("limit",40))}
                searchTextSaved=term
                LibrarySession.searchResults=page.getJSONArray("items").objects().onEach(::annotateDownloadState)
                LibrarySession.nextSearchIndex=page.optInt("nextStartIndex",-1)
                status="${page.optInt("totalCount")} matching titles"
            } catch(e:Exception) {status=e.message ?: "Search failed"}
            busy=false
        }
    }
    private fun annotateDownloadState(item:JSONObject) {
        val id=item.optString("id")
        item.put("downloaded",getSharedPreferences("library-downloads",0).contains("download_$id"))
    }
    private fun changeState(item:JSONObject, favorite:Boolean?=null, played:Boolean?=null) {
        if(busy) return
        busy=true
        lifecycleScope.launch {
            try {
                val request=command("state").put("itemID",item.getString("id"))
                favorite?.let {request.put("favorite",it)}; played?.let {request.put("played",it)}
                withContext(Dispatchers.IO) {CoreBridge.call(request)}
                favorite?.let {item.put("favorite",it)}; played?.let {item.put("played",it)}
                val home=withContext(Dispatchers.IO) {CoreBridge.call(command("home"))}
                LibrarySession.homeShelves=home.getJSONArray("shelves").objects()
                status="Library updated"
            } catch(e:Exception) {status=e.message ?: "Could not update library item"}
            busy=false
        }
    }
    private fun prepare(item:JSONObject,quality: String) {
        if(busy) return; busy=true; status="Preparing playback…"
        lifecycleScope.launch {
            try {
                val plan=withContext(Dispatchers.IO) { offlinePlan(item.getString("id")) ?: run {
                    val chosen=if(quality=="preferred") getPreferences(0).getString("libraryQuality","auto") ?: "auto" else quality
                    val request=command("playback").put("itemID",item.getString("id")).put("quality",chosen)
                    if(fixture?.optBoolean("startOver")==true) request.put("position",0)
                    val value=CoreBridge.call(request)
                    val segments=runCatching { CoreBridge.call(command("segments").put("itemID",item.getString("id"))).getJSONArray("segments") }.getOrNull()
                    if(segments!=null) value.put("segments",segments)
                    value.put("autoQuality",chosen=="auto")
                    if(quality!="preferred") getPreferences(0).edit().putString("libraryQuality",chosen).apply()
                    value
                } }
                    .put("server",LibrarySession.server).put("userID",LibrarySession.userID).put("itemID",item.getString("id"))
                busy=false
                val developer=fixture
                if(developer!=null) {
                    val track=plan.optJSONArray("subtitles").objects().firstOrNull {it.optBoolean("playable") && it.optString("language")==developer.optString("subtitleLanguage")}
                    launchPlan(plan,track?.optInt("index") ?: -1)
                } else if(plan.optJSONArray("subtitles").objects().any {it.optBoolean("playable")}) subtitles=plan else launchPlan(plan,-1)
            } catch(e: Exception) {busy=false; status=e.message ?: "Playback unavailable"}
        }
    }
    private fun offlinePlan(itemID:String):JSONObject? {
        val prefs=getSharedPreferences("library-downloads",0)
        val downloadID=prefs.getLong("download_$itemID",-1L)
        if(downloadID<0) return null
        val manager=getSystemService(DownloadManager::class.java)
        val query=DownloadManager.Query().setFilterById(downloadID)
        manager.query(query).use { cursor ->
            if(!cursor.moveToFirst() || cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))!=DownloadManager.STATUS_SUCCESSFUL) return null
            val mediaUri=cursor.getString(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI)) ?: return null
            val raw=prefs.getString("plan_$itemID",null) ?: return null
            val plan=JSONObject(raw).put("url",mediaUri).put("offline",true).put("subtitles",JSONArray()).put("subtitlesOff",true)
            val position=prefs.getLong("offline_position_$itemID",-1L)
            if(position>=0) plan.put("position",position/1000.0)
            return plan
        }
    }
    private fun syncOfflineProgress() {
        val prefs=getSharedPreferences("library-downloads",0)
        val pending=prefs.all.keys.filter {it.startsWith("offline_position_")}
        for(key in pending) {
            val itemID=key.removePrefix("offline_position_")
            val raw=prefs.getString("plan_$itemID",null) ?: continue
            try {
                val saved=JSONObject(raw)
                val seconds=prefs.getLong(key,0L)/1000.0
                val duration=saved.optDouble("duration")
                val request=command("offlineProgress").put("itemID",itemID).put("position",seconds)
                    .put("played",duration>0 && seconds>=duration*0.9)
                CoreBridge.call(request)
                prefs.edit().remove(key).apply()
            } catch (_:Exception) { return }
        }
    }
    private fun downloadForOffline(item:JSONObject) {
        val itemID=item.optString("id")
        if(busy || itemID.isBlank()) return
        val prefs=getSharedPreferences("library-downloads",0)
        if(prefs.contains("download_$itemID")) {
            val id=prefs.getLong("download_$itemID",-1L)
            if(id>=0) getSystemService(DownloadManager::class.java).remove(id)
            prefs.edit().remove("download_$itemID").remove("plan_$itemID").remove("offline_position_$itemID").apply()
            item.put("downloaded",false); status="Offline download removed"; return
        }
        busy=true; status="Preparing offline download…"
        lifecycleScope.launch {
            try {
                val (plan,download)=withContext(Dispatchers.IO) {
                    val playback=CoreBridge.call(command("playback").put("itemID",itemID).put("quality","original"))
                    val request=CoreBridge.call(command("download").put("itemID",itemID))
                    playback to request
                }
                plan.put("itemID",itemID)
                val tokenless=JSONObject(plan.toString()).put("authorization","").put("server","").put("userID","").put("url","")
                val destination="Convolution_${download.getString("fileName")}".replace("..","")
                val request=DownloadManager.Request(Uri.parse(download.getString("url")))
                    .addRequestHeader("Authorization",LibrarySession.authorization)
                    .setTitle(item.optString("name","Convolution title"))
                    .setDescription("Available for offline playback in Convolution")
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalFilesDir(this@MainActivity,Environment.DIRECTORY_MOVIES,destination)
                val id=getSystemService(DownloadManager::class.java).enqueue(request)
                getSharedPreferences("library-downloads",0).edit().putLong("download_$itemID",id).putString("plan_$itemID",tokenless.toString()).apply()
                item.put("downloaded",true)
                status="Download queued. Android will notify you when it is ready."
            } catch(e:Exception) {status=e.message ?: "Download unavailable"}
            busy=false
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
