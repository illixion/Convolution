/*
 Hypnos - RAVENet logging bridge

 RAVENet doesn't know about this app's logger, so it takes a sink. This
 forwards its transport diagnostics into the same `AppLogger.remoteViewer`
 category they used to be written to directly, so the in-app Console keeps
 showing them unchanged.
 */

import DebugTrace
import Foundation
import RAVENet

/// Forwards `RAVENet` transport logging into `AppLogger.remoteViewer`.
///
/// The sink receives finished strings, and RAVENet builds some of them from
/// the server URL and `localizedDescription` ("connecting to wss://…",
/// "receive error: …"). Without per-value privacy the whole line has to be
/// private: readable on this device's console in development builds,
/// `<private>` in exports.
struct RAVENetAppLogger: RAVENetLogger {
    func log(_ level: RAVENetLogLevel, _ message: String) {
        switch level {
        case .debug:
            AppLogger.remoteViewer.debug("WebSocket \(message)")
        case .info:
            AppLogger.remoteViewer.info("WebSocket \(message)")
        case .warning:
            AppLogger.remoteViewer.warning("WebSocket \(message)")
        case .error:
            AppLogger.remoteViewer.error("WebSocket \(message)")
        }
    }
}
