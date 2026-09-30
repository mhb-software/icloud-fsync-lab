import Foundation

/// An edit's identity: the device that made it and that device's edit number, written `ABCD1234#12`.
public struct EditID: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public var device: String
    public var number: Int

    public init(device: String, number: Int) {
        self.device = device
        self.number = number
    }

    public var description: String { "\(device)#\(number)" }

    public static func < (a: Self, b: Self) -> Bool { (a.device, a.number) < (b.device, b.number) }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad edit id \(text)"))
        }
        self.init(device: String(parts[0]), number: number)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// One entry in a document's history.
public struct EditRecord: Codable, Sendable, Hashable {
    public var edit: EditID
    /// The saving device's clock when the save began.
    public var at: Date
    public var action: Action
}

public struct FileCheck: Codable, Sendable, Hashable {
    public var size: Int
    public var sha256: String

    init(_ data: Data) {
        size = data.count
        sha256 = Blob.sha256(data)
    }
}

/// What the saving device writes inside `mix.json` so the other device can measure.
public struct Stamp: Codable, Sendable {
    public var documentID: UUID
    public var kind: StorageKind
    public var edit: EditID
    public var deviceName: String
    /// The saving device's clock when the save began.
    public var savedAt: Date
    public var action: Action
    public var style: WriteStyle
    public var sync: SyncMode
    /// Every edit this version contains, oldest first.
    public var history: [EditRecord]
    /// Size and checksum of every other file in the document.
    public var files: [String: FileCheck]
}

public enum DocumentError: LocalizedError {
    case missing(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): "missing \(path)"
        case .unreadable(let what): "cannot read \(what)"
        }
    }
}

/// `Info.json`, written once when the document is created.
struct Info: Codable, Sendable {
    var format = "software.mhb.fsynclab"
    var formatVersion = 1
    var kind: StorageKind
    var documentID: UUID
    var title: String
    var created: Date
}

/// `mix.json`: a stand in for Mix's description of a mix, about the same size, plus the stamp.
struct MixDescription: Codable, Sendable {
    struct Size: Codable, Sendable {
        var width: Double
        var height: Double
    }

    struct Image: Codable, Sendable {
        var original: String
        var thumbnail: String
        var contentRevision: Int
        var isSticker: Bool
    }

    struct Layer: Codable, Sendable {
        var layerId: String
        var type: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var zIndex: Double
        var rotationDegrees: Double
        var opacity: Double
        var isHidden: Bool
        var isLocked: Bool
        var maskShape: String
        var image: Image
    }

    var lab: Stamp
    var canvas: Size
    var thumbnail: String
    var layers: [Layer]
}

/// A whole document in memory, laid out like a `.mix`: `Info.json`, `mix.json`, `preview.jpg`,
/// and `resources/<sha256>.<ext>` for each photo and thumbnail.
public struct DocumentContent: Sendable {
    public enum Path {
        public static let info = "Info.json"
        public static let mix = "mix.json"
        public static let preview = "preview.jpg"
        public static let resources = "resources/"
    }

    var info: Info
    var mix: MixDescription
    var preview: Data
    var resources: [String: Data]

    public var stamp: Stamp { mix.lab }
    public var documentID: UUID { info.documentID }
    public var title: String { info.title }
    public var kind: StorageKind { info.kind }
    public var photoCount: Int { mix.layers.count }
    public var byteCount: Int { preview.count + resources.values.reduce(0) { $0 + $1.count } }

    /// A new document made the way Mix makes a collage: several photos at once, then one save.
    public static func new(
        title: String, kind: StorageKind, photos: Int, edit: EditID, deviceName: String,
        style: WriteStyle, sync: SyncMode, at date: Date = .now
    ) -> DocumentContent {
        let id = UUID()
        let thumbnail = resource(Blob.random(in: Sizes.mixThumbnail), ext: "heic")
        let stamp = Stamp(
            documentID: id, kind: kind, edit: edit, deviceName: deviceName, savedAt: date, action: .create,
            style: style, sync: sync, history: [EditRecord(edit: edit, at: date, action: .create)], files: [:])
        var content = DocumentContent(
            info: Info(kind: kind, documentID: id, title: title, created: date),
            mix: MixDescription(lab: stamp, canvas: .init(width: 1080, height: 1440), thumbnail: thumbnail.path, layers: []),
            preview: Blob.random(in: Sizes.preview),
            resources: [thumbnail.path: thumbnail.data])
        for _ in 0..<max(1, photos) { content.addPhotoLayer() }
        return content
    }

    /// Applies one action and stamps it, the way each action in Mix ends in a save.
    public mutating func apply(
        _ action: Action, edit: EditID, deviceName: String, style: WriteStyle, sync: SyncMode, at date: Date = .now
    ) {
        switch action {
        case .create: break
        case .move: moveLayer()
        case .addPhoto: addPhotoLayer()
        case .removePhoto: removePhotoLayer()
        case .close: replaceThumbnail()
        }
        preview = Blob.random(in: Sizes.preview)  // Mix renders a new preview on every save.
        mix.lab.edit = edit
        mix.lab.deviceName = deviceName
        mix.lab.savedAt = date
        mix.lab.action = action
        mix.lab.style = style
        mix.lab.sync = sync
        mix.lab.history.append(EditRecord(edit: edit, at: date, action: action))
    }

    /// Every file by relative path, with the stamp's checks filled in.
    public func files() throws -> [String: Data] {
        let encoder = Self.encoder()
        var files = resources
        files[Path.info] = try encoder.encode(info)
        files[Path.preview] = preview
        var mix = mix
        mix.lab.files = files.mapValues(FileCheck.init)
        files[Path.mix] = try encoder.encode(mix)
        return files
    }

    /// Rebuilds a document from its files. Checking them is `DocumentCheck`'s job.
    public init(files: [String: Data]) throws {
        let decoder = Self.decoder()
        guard let infoData = files[Path.info] else { throw DocumentError.missing(Path.info) }
        guard let mixData = files[Path.mix] else { throw DocumentError.missing(Path.mix) }
        guard let preview = files[Path.preview] else { throw DocumentError.missing(Path.preview) }
        let mix = try decoder.decode(MixDescription.self, from: mixData)
        var resources: [String: Data] = [:]
        for path in mix.layers.flatMap({ [$0.image.original, $0.image.thumbnail] }) + [mix.thumbnail] {
            guard let data = files[path] else { throw DocumentError.missing(path) }
            resources[path] = data
        }
        self.info = try decoder.decode(Info.self, from: infoData)
        self.mix = mix
        self.preview = preview
        self.resources = resources
    }

    private init(info: Info, mix: MixDescription, preview: Data, resources: [String: Data]) {
        self.info = info
        self.mix = mix
        self.preview = preview
        self.resources = resources
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]  // as Mix writes its JSON
        encoder.dateEncodingStrategy = .secondsSince1970  // keeps milliseconds
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - Actions

    private static func resource(_ data: Data, ext: String) -> (path: String, data: Data) {
        (Path.resources + Blob.sha256(data) + "." + ext, data)
    }

    private mutating func addPhotoLayer() {
        let original = Self.resource(Blob.random(in: Sizes.photo), ext: "heic")
        let thumbnail = Self.resource(Blob.random(in: Sizes.photoThumbnail), ext: "heic")
        resources[original.path] = original.data
        resources[thumbnail.path] = thumbnail.data
        let side = Double.random(in: 240...720)
        mix.layers.append(
            .init(
                layerId: UUID().uuidString, type: "image",
                x: .random(in: 0...mix.canvas.width), y: .random(in: 0...mix.canvas.height),
                width: side, height: side * .random(in: 0.66...1.5),
                zIndex: Double(mix.layers.count), rotationDegrees: 0, opacity: 1,
                isHidden: false, isLocked: false, maskShape: "none",
                image: .init(original: original.path, thumbnail: thumbnail.path, contentRevision: 0, isSticker: false)))
    }

    private mutating func moveLayer() {
        guard !mix.layers.isEmpty else { return }
        let index = Int.random(in: mix.layers.indices)
        mix.layers[index].x += .random(in: -80...80)
        mix.layers[index].y += .random(in: -80...80)
        mix.layers[index].rotationDegrees = .random(in: -15...15)
    }

    private mutating func removePhotoLayer() {
        guard mix.layers.count > 1 else { return moveLayer() }
        let layer = mix.layers.remove(at: Int.random(in: mix.layers.indices))
        let stillUsed = Set(mix.layers.flatMap { [$0.image.original, $0.image.thumbnail] })
        for path in [layer.image.original, layer.image.thumbnail] where !stillUsed.contains(path) {
            resources[path] = nil
        }
    }

    /// Mix writes a new gallery thumbnail when the editor closes.
    private mutating func replaceThumbnail() {
        resources[mix.thumbnail] = nil
        let thumbnail = Self.resource(Blob.random(in: Sizes.mixThumbnail), ext: "heic")
        resources[thumbnail.path] = thumbnail.data
        mix.thumbnail = thumbnail.path
    }
}
