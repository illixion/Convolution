/*
 Hypnos - Shared Media Saver

 Saves shared media files to the app's Documents/Photos or Documents/Videos folder.
 */

import DebugTrace
import Foundation

enum SharedMediaSaver {
    /// Save a shared image to Documents/Photos/
    static func saveImage(from sourceURL: URL, originalFileName: String) throws -> URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let photosDir = documentsDir.appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)

        let destinationURL = uniqueDestination(directory: photosDir, fileName: originalFileName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        AppLogger.sharedMedia.info("Saved shared photo to: \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    /// Save a shared video to Documents/Videos/
    static func saveVideo(from sourceURL: URL, originalFileName: String) throws -> URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let videosDir = documentsDir.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)

        let destinationURL = uniqueDestination(directory: videosDir, fileName: originalFileName)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        AppLogger.sharedMedia.info("Saved shared video to: \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    /// Generate a unique filename to avoid collisions
    private static func uniqueDestination(directory: URL, fileName: String) -> URL {
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var destination = directory.appendingPathComponent(fileName)
        var counter = 1

        while FileManager.default.fileExists(atPath: destination.path) {
            let newName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            destination = directory.appendingPathComponent(newName)
            counter += 1
        }

        return destination
    }
}
