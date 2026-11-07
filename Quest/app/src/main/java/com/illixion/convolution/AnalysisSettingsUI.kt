package com.illixion.convolution

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Settings → Analysis computer: pair with a Vergence coordinator (the desktop
 * app or the home server's `vergenced`) by its six-digit code, or paste its
 * address and a token as the Vision Pro's Analysis Server section takes
 * them. Smooth Motion for 3D titles reads the fields it prepares.
 */
@Composable
fun AnalysisSettingsSection() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var summary by remember { mutableStateOf(AnalysisSettings.summary(context)) }
    var smooth by remember { mutableStateOf(AnalysisSettings.smoothMotion(context)) }
    var found by remember { mutableStateOf<List<CoordinatorDiscovery.Found>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf<Pair<String, String>?>(null) }
    var message by remember { mutableStateOf("") }
    var manual by remember { mutableStateOf(false) }
    var address by remember { mutableStateOf(AnalysisSettings.address(context)) }
    var token by remember { mutableStateOf("") }
    var link by remember { mutableStateOf("") }
    val client = remember { CoordinatorPairingClient() }
    val discovery = remember { CoordinatorDiscovery(context) { found = it } }
    DisposableEffect(Unit) { onDispose { discovery.stop(); client.cancel() } }

    fun pair(host: String, port: Int) {
        code = null; message = "Connecting…"
        client.pair(host, port, AnalysisSettings.deviceId(context), "Quest (${Build.MODEL})", object : CoordinatorPairingClient.Listener {
            override fun onCode(code6: String, hostName: String) {
                code = "${code6.take(3)} ${code6.drop(3)}" to hostName
                message = "Check that $hostName shows the same code, then press Pair there."
            }
            override fun onPaired(result: CoordinatorPairingClient.Result) {
                val host = result.addresses.first()
                AnalysisSettings.savePaired(context, host, result.hostId, result.hostName, result.addresses, result.token)
                code = null; summary = AnalysisSettings.summary(context); address = host
                message = "Paired with ${result.hostName}."
            }
            override fun onFailed(text: String) { code = null; message = text }
        })
    }

    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0xFF30303A)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Analysis computer", style = MaterialTheme.typography.titleMedium)
        Text(summary ?: "Pair with the Vergence app on a Mac or PC (or a Vergence server) so it prepares Smooth Motion for 3D titles while you watch.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Smooth Motion for 3D titles", style = MaterialTheme.typography.bodyLarge)
                Text("In-between frames from the analysis computer's fields. Plays as usual where it hasn't any yet.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(checked = smooth, onCheckedChange = { smooth = it; AnalysisSettings.setSmoothMotion(context, it) })
        }
        code?.let { (digits, host) ->
            Text(digits, fontFamily = FontFamily.Monospace, fontSize = 40.sp, color = Color.White)
            Text("Shown on $host too?", style = MaterialTheme.typography.bodyMedium)
            OutlinedButton(onClick = { client.cancel() }) { Text("Cancel") }
        }
        if (code == null) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = {
                    if (searching) { discovery.stop(); searching = false } else { found = emptyList(); discovery.start(); searching = true }
                }) { Text(if (searching) "Stop looking" else "Find computers") }
                OutlinedButton(onClick = { manual = !manual }) { Text(if (manual) "Hide address" else "Enter address") }
            }
            if (searching && found.isEmpty()) Text("Open Vergence on your computer and choose Pair a headset.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            found.forEach { computer ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(computer.name + if (computer.pairing) "" else " (not pairing now)", Modifier.weight(1f))
                    TextButton(onClick = { pair(computer.host, computer.port) }) { Text("Pair") }
                }
            }
            if (manual) {
                Text("Pair by address: the computer's address (Vergence shows it while pairing), or its whole vergence://pair link.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(link, { link = it }, label = { Text("192.168.1.20 or vergence://pair?…") }, singleLine = true)
                TextButton(onClick = {
                    val target = pairTarget(link)
                    if (target == null) message = "Enter the computer's address or its vergence://pair link."
                    else pair(target.first, target.second)
                }) { Text("Pair") }
                Text("Or a Vergence server's HTTP address and a play token:", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(address, { address = it }, singleLine = true,
                    label = { Text(if (AnalysisSettings.isPaired(context)) "Paired computer's address" else "Server (http://host:8420)") })
                OutlinedTextField(token, { token = it }, label = { Text("Token") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = {
                        val base = coordinatorBaseUrl(address, AnalysisSettings.DEFAULT_HTTP_PORT)
                        when {
                            token.isBlank() && AnalysisSettings.isPaired(context) && address.isNotBlank() -> {
                                AnalysisSettings.setPairedHost(context, address.trim()); summary = AnalysisSettings.summary(context); message = "Address saved."
                            }
                            base == null -> message = "Enter the server's address."
                            token.isBlank() -> message = "Enter the token `vergenced token add NAME --grants play` printed."
                            else -> {
                                AnalysisSettings.saveManual(context, base, token.trim()); token = ""
                                summary = AnalysisSettings.summary(context); message = "Saved."
                            }
                        }
                    }) { Text("Save") }
                    TextButton(onClick = {
                        message = "Checking…"
                        scope.launch {
                            message = withContext(Dispatchers.IO) {
                                val config = AnalysisSettings.current(context) ?: return@withContext "No analysis computer is set."
                                val client = CoordinatorClient(config)
                                try {
                                    if (client.healthy()) "The analysis computer answers." else "It answered, but not as a Vergence server."
                                } catch (e: Exception) { "Couldn't reach it (${e.javaClass.simpleName})." } finally { client.close() }
                            }
                        }
                    }) { Text("Test") }
                }
            }
            if (summary != null) TextButton(onClick = { AnalysisSettings.forget(context); summary = null; message = "Forgotten. Remove this Quest from Vergence's Devices list too." }) {
                Text("Forget this computer")
            }
        }
        if (message.isNotEmpty()) Text(message, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
