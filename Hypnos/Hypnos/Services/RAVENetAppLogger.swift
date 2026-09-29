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

/// Forwards `RAVENet` transport logging into `AppLogger.remoteViewer`,
/// keeping RAVENet's per-value privacy: timings, counts and error codes stay
/// public, the server endpoint (query already dropped) and error text don't.
struct RAVENetAppLogger: RAVENetLogger {
    func log(_ level: RAVENetLogLevel, _ message: DebugLogMessage) {
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
