package com.illixion.convolution

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.PasswordVisualTransformation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

private val Ink = Color(0xFF101016)
private val CardInk = Color(0xFF1D1D26)
private val Accent = Color(0xFFB9A2FF)

@Composable
fun ConvolutionTheme(content: @Composable () -> Unit) {
    val colors = darkColorScheme(
        primary = Accent, onPrimary = Ink, background = Ink, onBackground = Color(0xFFF5F3FA),
        surface = CardInk, onSurface = Color(0xFFF5F3FA), surfaceVariant = Color(0xFF292832),
        onSurfaceVariant = Color(0xFFC8C4D0)
    )
    MaterialTheme(colorScheme = colors) {
        Surface(color = colors.background, contentColor = colors.onBackground) { content() }
    }
}

@Composable
fun LibraryBrowser(
    items: List<JSONObject>, shelves: List<JSONObject>, searchItems: List<JSONObject>, selected: JSONObject?, status: String, busy: Boolean,
    onSelect: (JSONObject) -> Unit, onBack: () -> Unit, onPlay: (JSONObject, String) -> Unit,
    onLoadMore: (Boolean) -> Unit, onSearch: (String) -> Unit,
    onStateChange: (JSONObject, Boolean?, Boolean?) -> Unit,
    onDownload: (JSONObject) -> Unit,
    onSignOut: () -> Unit, onOpenSettings: () -> Unit, onOpenPlayer: () -> Unit,
) {
    var tab by remember { mutableStateOf("Home") }
    var searchText by remember { mutableStateOf("") }
    val movies = remember(items) { items.filter { it.optString("type") != "Episode" } }
    val episodes = remember(items) { items.filter { it.optString("type") == "Episode" } }
    val resume = remember(items) { items.filter { it.optDouble("position") > 30.0 } }
    val newest = remember(items) { items.sortedByDescending { it.optString("dateCreated") } }
    val active = when (tab) { "Movies" -> movies; "Episodes" -> episodes; "Search" -> searchItems; else -> items }

    Column(Modifier.fillMaxSize().background(Ink).padding(horizontal = 30.dp, vertical = 20.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (selected != null) {
                IconPill("‹", onBack)
                Spacer(Modifier.width(18.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(if (selected == null) "CONVOLUTION" else "LIBRARY  /  ${selected.optString("type", "MOVIE").uppercase()}", style = MaterialTheme.typography.labelMedium, color = Accent, fontWeight = FontWeight.Bold)
                Text(if (selected == null) tab else selected.optString("name"), style = MaterialTheme.typography.headlineSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (selected == null) {
                TextButton(onClick = onOpenSettings) { Text("Settings") }
                TextButton(onClick = onSignOut) { Text("Sign out") }
            }
        }
        Spacer(Modifier.height(14.dp))

        if (selected != null) {
            DetailPage(selected, busy, onPlay, onStateChange, onDownload)
        } else {
            LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(22.dp), contentPadding = PaddingValues(bottom = 16.dp)) {
                if (tab == "Home" && shelves.isNotEmpty()) {
                    val featured = shelves.firstNotNullOfOrNull { it.optJSONArray("items")?.objects()?.firstOrNull() }
                    if (featured != null) item { FeaturedTitle(featured, onSelect) }
                    shelves.forEach { shelf ->
                        val shelfItems=shelf.optJSONArray("items")?.objects().orEmpty()
                        if(shelfItems.isNotEmpty()) item { Shelf(shelf.optString("title"),shelfItems,onSelect) }
                    }
                } else if (tab == "Home" && items.isNotEmpty()) {
                    item { FeaturedTitle(newest.first(), onSelect) }
                    if (resume.isNotEmpty()) item { Shelf("Continue Watching", resume, onSelect) }
                    if (newest.isNotEmpty()) item { Shelf("Recently Added", newest.take(20), onSelect) }
                    if (movies.isNotEmpty()) item { Shelf("Movies", movies.take(20), onSelect) }
                    if (episodes.isNotEmpty()) item { Shelf("Episodes", episodes.take(20), onSelect) }
                } else {
                    if(tab == "Search") item {
                        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)) {
                            OutlinedTextField(searchText,{searchText=it},label={Text("Search Jellyfin")},singleLine=true,modifier=Modifier.weight(1f))
                            Button(enabled=!busy && searchText.isNotBlank(),onClick={onSearch(searchText)}) {Text("Search")}
                        }
                    }
                    item { Shelf(if (tab == "Episodes") "Episodes" else if(tab=="Search") "Results" else "Movies", active, onSelect, large = true) }
                    val canLoadMore=if(tab=="Search") LibrarySession.nextSearchIndex>=0 else LibrarySession.nextCatalogIndex>=0
                    if(canLoadMore) item {
                        Button(enabled=!busy,onClick={onLoadMore(tab=="Search")},modifier=Modifier.fillMaxWidth()) {Text(if(busy) "Loading…" else "Load more")}
                    }
                }
                if (items.isEmpty()) item { Text("Your Jellyfin library will appear here after sign in.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
                if (busy) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
                if (status.isNotBlank()) item { Text(status, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }

        PlaybackDock(onOpen = onOpenPlayer)
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.Center) {
            Surface(shape = CircleShape, color = Color(0xFF26252E)) {
                Row(Modifier.padding(horizontal = 14.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    listOf("Home", "Movies", "Episodes", "Search").forEach { destination ->
                        TextButton(onClick = { tab = destination; if (selected != null) onBack() }) {
                            Text(destination, color = if (tab == destination) Accent else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun SignInPanel(
    server: String, onServer: (String) -> Unit, username: String, onUsername: (String) -> Unit,
    password: String, onPassword: (String) -> Unit, busy: Boolean, status: String, onSignIn: () -> Unit,
) {
    Row(Modifier.fillMaxSize().background(Ink).padding(36.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 48.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("CONVOLUTION", style = MaterialTheme.typography.labelLarge, color = Accent, fontWeight = FontWeight.Bold)
            Text("Your library,\nin your space.", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.SemiBold)
            Text("Connect Jellyfin to browse your films and shows.", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Surface(Modifier.width(400.dp), shape = RoundedCornerShape(24.dp), color = CardInk) {
            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Sign in to Jellyfin", style = MaterialTheme.typography.titleLarge)
                OutlinedTextField(server, onServer, label = { Text("Server URL") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(username, onUsername, label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(password, onPassword, label = { Text("Password") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
                Button(enabled = !busy, onClick = onSignIn, modifier = Modifier.fillMaxWidth()) { Text("Sign in") }
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (status.isNotBlank()) Text(status, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun FeaturedTitle(item: JSONObject, onSelect: (JSONObject) -> Unit) {
    Surface(shape = RoundedCornerShape(24.dp), color = CardInk, modifier = Modifier.fillMaxWidth().height(210.dp).clickable { onSelect(item) }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Poster(item, Modifier.width(145.dp).fillMaxHeight())
            Column(Modifier.weight(1f).padding(horizontal = 26.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("FEATURED FROM YOUR LIBRARY", style = MaterialTheme.typography.labelMedium, color = Accent)
                Text(item.optString("name"), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(metadata(item), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(item.optString("overview").ifBlank { "Open details to see playback options." }, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Button(onClick = { onSelect(item) }, modifier = Modifier.padding(end = 24.dp)) { Text("View details") }
        }
    }
}

@Composable
private fun Shelf(title: String, items: List<JSONObject>, onSelect: (JSONObject) -> Unit, large: Boolean = false) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Medium)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            items(items, key = { it.optString("id") }) { item ->
                Column(Modifier.width(if (large) 176.dp else 140.dp).clickable { onSelect(item) }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Poster(item, Modifier.fillMaxWidth().height(if (large) 224.dp else 184.dp))
                    Text(item.optString("name"), style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(metadata(item), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun Poster(item: JSONObject, modifier: Modifier = Modifier) {
    val id = item.optString("id")
    val bitmap by produceState<Bitmap?>(null, id, LibrarySession.server, LibrarySession.authorization) {
        value = PosterCache[id]
        if (value == null && item.optBoolean("hasPoster")) {
            value = withContext(Dispatchers.IO) { loadPoster(id) }
            value?.let { PosterCache.put(id, it) }
        }
    }
    Surface(modifier.clip(RoundedCornerShape(14.dp)), color = Color(0xFF34323D)) {
        Box(contentAlignment = Alignment.Center) {
            if (bitmap != null) androidx.compose.foundation.Image(bitmap!!.asImageBitmap(), contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else Text(item.optString("name").take(1).uppercase(), style = MaterialTheme.typography.displayMedium, color = Accent)
        }
    }
}

private object PosterCache : LruCache<String, Bitmap>(24 * 1024 * 1024) {
    override fun sizeOf(key: String, value: Bitmap) = value.byteCount
}

private fun loadPoster(id: String): Bitmap? = try {
    val url = URL("${LibrarySession.server.trimEnd('/')}/Items/$id/Images/Primary?maxWidth=600")
    (url.openConnection() as HttpURLConnection).run {
        connectTimeout = 8000; readTimeout = 8000
        setRequestProperty("Authorization", LibrarySession.authorization)
        try { if (responseCode == 200) inputStream.use { BitmapFactory.decodeStream(it) } else null }
        finally { disconnect() }
    }
} catch (_: Exception) { null }

@Composable
private fun DetailPage(item: JSONObject, busy: Boolean, onPlay: (JSONObject, String) -> Unit,
                       onStateChange: (JSONObject, Boolean?, Boolean?) -> Unit,
                       onDownload: (JSONObject) -> Unit) {
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 12.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            Poster(item, Modifier.width(210.dp).height(310.dp))
            Column(Modifier.weight(1f).padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(metadata(item), style = MaterialTheme.typography.titleMedium, color = Accent)
                Text(item.optString("overview").ifBlank { "No description is available for this title." }, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(enabled = !busy, onClick = { onPlay(item, "preferred") }) { Text(if (item.optDouble("position") > 30.0) "Resume" else "Play") }
                    OutlinedButton(enabled = !busy, onClick = { onPlay(item, "original") }) { Text("Original quality") }
                }
                TextButton(enabled = !busy, onClick = { onPlay(item, "choose") }) { Text("More playback options") }
                Row(horizontalArrangement=Arrangement.spacedBy(10.dp)) {
                    OutlinedButton(enabled=!busy,onClick={onStateChange(item,!item.optBoolean("favorite"),null)}) {Text(if(item.optBoolean("favorite")) "Remove favorite" else "Favorite")}
                    OutlinedButton(enabled=!busy,onClick={onStateChange(item,null,!item.optBoolean("played"))}) {Text(if(item.optBoolean("played")) "Mark unwatched" else "Mark watched")}
                }
                if(item.optBoolean("canDownload")) OutlinedButton(enabled=!busy,onClick={onDownload(item)}) {Text(if(item.optBoolean("downloaded")) "Remove offline download" else "Download for offline")}
                if (item.optDouble("position") > 30.0) Text("Resume at ${clock(item.optDouble("position"))}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (item.optString("stereo") != "Mono") Text("Stereoscopic · ${item.optString("stereo")}", color = Accent)
            }
        }
    }
}

@Composable
private fun PlaybackDock(onOpen: () -> Unit) {
    val session = PlaybackSession.current() ?: return
    var paused by remember { mutableStateOf(session.paused()) }
    var position by remember { mutableIntStateOf(session.position().toInt()) }
    var duration by remember { mutableIntStateOf(session.duration().toInt()) }
    LaunchedEffect(session) { while (true) { paused = session.paused(); position = session.position().toInt(); duration = session.duration().toInt(); kotlinx.coroutines.delay(500) } }
    Surface(shape = RoundedCornerShape(18.dp), color = Color(0xFF22212A), modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(session.title(), Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.Medium)
            Text("${clock(position.toDouble())} / ${clock(duration.toDouble())}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            IconPill(if (paused) "▶" else "Ⅱ") {
                if (paused) onOpen() else { session.toggleVideo(); paused = true }
            }
            TextButton(onClick = onOpen) { Text("Player") }
        }
    }
}

@Composable
fun SpatialSettingsPanel(onClose: () -> Unit, onSignOut: () -> Unit, spatialWindowsSupported: Boolean) {
    Surface(Modifier.fillMaxSize(), color = Color(0xFF24232C), shape = RoundedCornerShape(24.dp)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) { Text("CONVOLUTION", style = MaterialTheme.typography.labelSmall, color = Accent); Text("Settings", style = MaterialTheme.typography.headlineMedium) }
                IconPill("×", onClose)
            }
            SettingsRow("Playback", "Choose stream quality and subtitle language before playback.")
            SettingsRow("Presentation", "Play beside Home, or switch to the movable spatial screen.")
            SettingsRow("Library", "Jellyfin · ${LibrarySession.catalog.size} titles")
            OutlinedButton(onClick = onSignOut) { Text("Sign out") }
            Text(if (spatialWindowsSupported) "This settings panel is a separate Horizon window. Drag it beside your library." else "This headset is using the inline settings fallback because spatial windows are unavailable.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SettingsRow(title: String, summary: String) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFF30303A)).padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(summary, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun IconPill(label: String, onClick: () -> Unit) {
    Surface(shape = CircleShape, color = Color(0xFF34323D), modifier = Modifier.sizeIn(minWidth = 42.dp, minHeight = 42.dp).clickable(onClick = onClick)) {
        Box(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), contentAlignment = Alignment.Center) { Text(label, color = Color.White, style = MaterialTheme.typography.titleMedium) }
    }
}

private fun metadata(item: JSONObject): String = listOfNotNull(
    item.optInt("year").takeIf { it > 0 }?.toString(),
    item.optString("type").takeIf { it == "Episode" }?.let { item.optString("series") },
    item.optDouble("duration").takeIf { it > 0 }?.let { "${(it / 60).toInt()} min" },
).joinToString("  ·  ")

private fun clock(seconds: Double): String = "${seconds.toInt().coerceAtLeast(0) / 60}:${(seconds.toInt().coerceAtLeast(0) % 60).toString().padStart(2, '0')}"
private fun org.json.JSONArray.objects(): List<JSONObject> = (0 until length()).mapNotNull { optJSONObject(it) }
