import Foundation

/// What one save cost on the saving device.
public struct WriteReport: Sendable {
    public var seconds: Double
    public var bytesWritten: Int
}

/// Writes documents in each style. Every write is coordinated, as an iCloud app's must be.
public enum DocumentWriter {
    /// Writes `content` at `url` in `style` and times it, encoding and checksums included,
    /// since Mix hashes its blobs on every save too.
    public static func write(_ content: DocumentContent, to url: URL, style: WriteStyle) throws -> WriteReport {
        let kind = content.kind
        precondition(kind.writeStyles.contains(style), "\(style) is not a write style for \(kind)")
        let start = ContinuousClock.now
        let files = try content.files()
        let bytes: Int
        switch (kind, style) {
        case (.zip, .deleteThenCreate): bytes = try zipDeleteThenCreate(files, url)
        case (.zip, .swapTemp): bytes = try swapIn(url) { try ZipCodec.write(files, to: $0); return fileSize($0) }
        case (.zip, _): bytes = try zipOverwrite(files, url)
        case (_, .deleteThenCreate): bytes = try treeDeleteThenCreate(files, url)
        case (_, .swapTemp): bytes = try swapIn(url) { try writeTree(files, at: $0) }
        case (_, .changedSwapped): bytes = try writeChanged(files, url, atomically: true)
        case (_, _): bytes = try writeChanged(files, url, atomically: false)
        }
        return WriteReport(seconds: (ContinuousClock.now - start).seconds, bytesWritten: bytes)
    }

    private static func zipDeleteThenCreate(_ files: [String: Data], _ url: URL) throws -> Int {
        try deleteIfPresent(url)
        var bytes = 0
        try Coordination.write(url) { url in
            try ZipCodec.write(files, to: url)
            bytes = fileSize(url)
        }
        return bytes
    }

    private static func zipOverwrite(_ files: [String: Data], _ url: URL) throws -> Int {
        let data = try ZipCodec.data(files)
        try Coordination.write(url) { try overwrite($0, with: data) }
        return data.count
    }

    private static func treeDeleteThenCreate(_ files: [String: Data], _ url: URL) throws -> Int {
        try deleteIfPresent(url)
        var bytes = 0
        try Coordination.write(url) { bytes = try writeTree(files, at: $0) }
        return bytes
    }

    private static func deleteIfPresent(_ url: URL) throws {
        try Coordination.write(url, options: .forDeleting) { url in
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Writes a complete new copy in a temporary folder on the same volume, then swaps it in.
    private static func swapIn(_ url: URL, build: (URL) throws -> Int) throws -> Int {
        let fileManager = FileManager.default
        let scratch = try fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url.deletingLastPathComponent(),
            create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(url.lastPathComponent)
        let bytes = try build(copy)
        try Coordination.write(url, options: .forReplacing) { url in
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: copy)
            } else {
                try fileManager.moveItem(at: copy, to: url)
            }
        }
        return bytes
    }

    /// Replaces a file's bytes but keeps the file itself, so it stays the same item.
    static func overwrite(_ url: URL, with data: Data) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return try data.write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
    }

    /// Writes every file under `root`, creating folders as needed. Returns the bytes written.
    static func writeTree(_ files: [String: Data], at root: URL) throws -> Int {
        let fileManager = FileManager.default
        var bytes = 0
        for (path, data) in ZipCodec.orderedEntries(files) {
            let file = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            bytes += data.count
        }
        return bytes
    }

    /// Writes only what changed: `mix.json` and the preview always, `Info.json` when it differs,
    /// resources that are new, and removes resources no longer used. Other files are left alone,
    /// so a stray conflict copy stays where the reader will notice it.
    private static func writeChanged(_ files: [String: Data], _ url: URL, atomically: Bool) throws -> Int {
        let fileManager = FileManager.default
        var bytes = 0
        try Coordination.write(url) { root in
            let resources = root.appendingPathComponent(DocumentContent.Path.resources)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            for (path, data) in ZipCodec.orderedEntries(files) {
                let file = root.appendingPathComponent(path)
                if path.hasPrefix(DocumentContent.Path.resources), fileManager.fileExists(atPath: file.path) {
                    continue  // named by their contents, so an existing one is unchanged
                }
                if path == DocumentContent.Path.info, (try? Data(contentsOf: file)) == data { continue }
                if atomically {
                    try data.write(to: file, options: .atomic)
                } else {
                    try overwrite(file, with: data)
                }
                bytes += data.count
            }
            for name in try fileManager.contentsOfDirectory(atPath: resources.path)
            where !name.hasPrefix(".") && files[DocumentContent.Path.resources + name] == nil {
                try fileManager.removeItem(at: resources.appendingPathComponent(name))
            }
        }
        return bytes
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// File coordination, so iCloud and other readers see each write as one change.
enum Coordination {
    static func write(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) {
            url in
            do { try body(url) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }

    static func read<T>(_ url: URL, options: NSFileCoordinator.ReadingOptions = [], _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: options, error: &coordinationError) {
            url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DocumentError.unreadable(url.lastPathComponent) }
        return try result.get()
    }
}
