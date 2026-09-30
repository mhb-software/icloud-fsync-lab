import Foundation
import ZIPFoundation

/// Writes and reads the zip the way Mix's `.mix` writer does: `Info.json`, `mix.json`, then
/// `preview.jpg`, then the resources in name order. JSON is compressed; images are stored.
enum ZipCodec {
    static func orderedEntries(_ files: [String: Data]) -> [(path: String, data: Data)] {
        let head = [DocumentContent.Path.info, DocumentContent.Path.mix, DocumentContent.Path.preview]
        let rest = files.keys.filter { !head.contains($0) }.sorted()
        return (head + rest).compactMap { path in files[path].map { (path, $0) } }
    }

    static func isCompressed(_ path: String) -> Bool {
        path.hasSuffix(".json") || path.hasSuffix(".plist") || path.hasSuffix(".dat")
    }

    /// Builds the archive at `url` one entry at a time, as Mix does. `url` must not exist yet.
    static func write(_ files: [String: Data], to url: URL) throws {
        try add(files, to: try Archive(url: url, accessMode: .create))
    }

    /// The whole archive in memory.
    static func data(_ files: [String: Data]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        try add(files, to: archive)
        guard let data = archive.data else { throw DocumentError.unreadable("the zip in memory") }
        return data
    }

    private static func add(_ files: [String: Data], to archive: Archive) throws {
        for (path, data) in orderedEntries(files) {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: isCompressed(path) ? .deflate : .none,
                provider: { position, size in data.subdata(in: Int(position)..<(Int(position) + size)) })
        }
    }

    /// Every file in the archive. Extracting checks each entry's CRC.
    static func read(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var files: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            files[entry.path] = data
        }
        return files
    }
}
