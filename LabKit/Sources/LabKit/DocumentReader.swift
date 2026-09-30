import Foundation

/// A document as read from disk: its content if it loaded, and anything wrong with it.
public struct ReadResult: Sendable {
    public var content: DocumentContent?
    public var problems: [String]
    public var byteCount: Int

    public var stamp: Stamp? { content?.stamp }
    public var isConsistent: Bool { content != nil && problems.isEmpty }
}

public enum DocumentReader {
    /// Reads a document and checks it. Pass `coordinated: false` for an `NSFileVersion`'s copy.
    public static func read(_ url: URL, kind: StorageKind, coordinated: Bool = true) -> ReadResult {
        do {
            let files =
                coordinated
                ? try Coordination.read(url) { try readFiles($0, kind: kind) }
                : try readFiles(url, kind: kind)
            return DocumentCheck.check(files)
        } catch {
            return ReadResult(content: nil, problems: ["unreadable: \(error.localizedDescription)"], byteCount: 0)
        }
    }

    /// Just the stamp inside one `mix.json`, for a conflict version of that single file.
    public static func stamp(inMixJSON url: URL) -> Stamp? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? DocumentContent.decoder().decode(MixDescription.self, from: data).lab
    }

    static func readFiles(_ url: URL, kind: StorageKind) throws -> [String: Data] {
        switch kind {
        case .zip: try ZipCodec.read(url)
        case .package, .folder: try readTree(url)
        }
    }

    /// Every regular file under `root` by relative path, skipping hidden files.
    static func readTree(_ root: URL) throws -> [String: Data] {
        let root = root.resolvingSymlinksInPath()
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { throw DocumentError.unreadable(root.lastPathComponent) }
        let depth = root.pathComponents.count
        var files: [String: Data] = [:]
        for case let file as URL in enumerator
        where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = file.resolvingSymlinksInPath().pathComponents.dropFirst(depth).joined(separator: "/")
            files[path] = try Data(contentsOf: file)
        }
        return files
    }
}

public enum DocumentCheck {
    /// Parses the files and compares each one with the size and checksum the stamp recorded.
    /// A mismatch means the files came from different saves: a torn or mixed document.
    public static func check(_ files: [String: Data]) -> ReadResult {
        let bytes = files.values.reduce(0) { $0 + $1.count }
        guard let mixData = files[DocumentContent.Path.mix] else {
            return ReadResult(content: nil, problems: ["missing mix.json"], byteCount: bytes)
        }
        guard let mix = try? DocumentContent.decoder().decode(MixDescription.self, from: mixData) else {
            return ReadResult(content: nil, problems: ["mix.json does not parse"], byteCount: bytes)
        }
        var problems: [String] = []
        for (path, check) in mix.lab.files.sorted(by: { $0.key < $1.key }) {
            guard let data = files[path] else {
                problems.append("missing \(path)")
                continue
            }
            if data.count != check.size || Blob.sha256(data) != check.sha256 {
                problems.append("\(path) is from another save")
            }
        }
        for path in files.keys.sorted() where path != DocumentContent.Path.mix && mix.lab.files[path] == nil {
            problems.append("unexpected \(path)")
        }
        let content = try? DocumentContent(files: files)
        if content == nil, problems.isEmpty { problems.append("does not load") }
        return ReadResult(content: content, problems: problems, byteCount: bytes)
    }
}
