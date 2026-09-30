import Foundation
import LabKit

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Saving logs where they can be read: a folder picked once and remembered, filled with this
/// device's log, the results table, and every linked device's log, fetched over the link.
extension Lab {
    static let exportFolderKey = "exportFolder"

    func setExportFolder(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
            let bookmark = try? url.bookmarkData()
        #endif
        UserDefaults.standard.set(bookmark, forKey: Self.exportFolderKey)
        exportFolderName = bookmark == nil ? nil : url.lastPathComponent
        if bookmark == nil { record("error", nil, "cannot remember the folder \(url.path)") }
    }

    func exportFolder() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.exportFolderKey) else { return nil }
        var stale = false
        #if os(macOS)
            let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
            let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        #endif
        if stale, let url { setExportFolder(url) }
        return url
    }

    func saveLogs() async {
        guard let folder = exportFolder() else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let stamp = Self.exportTime.string(from: .now)
        var saved: [String] = []
        func write(_ data: Data, _ name: String) {
            let file = folder.appending(path: "\(stamp) \(name)")
            do {
                try data.write(to: file)
                saved.append(file.lastPathComponent)
            } catch {
                record("error", nil, "could not save \(file.lastPathComponent): \(Self.describe(error))")
            }
        }
        try? logHandle?.synchronize()
        if let log = try? Data(contentsOf: Self.logURL) { write(log, "\(Self.fileSafe(device.name)) log.jsonl") }
        write(Data(csv.utf8), "results.csv")
        for (peer, log) in await link.requestLogs() {
            write(log, "\(Self.fileSafe(peer.name)) log.jsonl")
        }
        record("saved", nil, "saved \(saved.count) files to \(folder.lastPathComponent): \(saved.joined(separator: ", "))")
    }

    func openExportFolder() {
        guard let folder = exportFolder() else { return }
        #if os(macOS)
            let accessing = folder.startAccessingSecurityScopedResource()
            NSWorkspace.shared.open(folder)
            if accessing { folder.stopAccessingSecurityScopedResource() }
        #else
            if let url = URL(string: "shareddocuments://" + folder.path(percentEncoded: true)) {
                UIApplication.shared.open(url)
            }
        #endif
    }

    private static let exportTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private static func fileSafe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }
}
