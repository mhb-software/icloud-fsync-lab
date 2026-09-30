import Foundation

/// How a document is stored, chosen when it is created.
public enum StorageKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case zip, package, folder

    public var id: Self { self }

    /// The file name extension, which is also how a document's kind is recognized.
    public var fileExtension: String {
        switch self {
        case .zip: "labzip"
        case .package: "labpkg"
        case .folder: "labfolder"
        }
    }

    public init?(url: URL) {
        guard let kind = Self.allCases.first(where: { $0.fileExtension == url.pathExtension }) else { return nil }
        self = kind
    }

    /// The ways this kind can be written.
    public var writeStyles: [WriteStyle] {
        switch self {
        case .zip: [.deleteThenCreate, .swapTemp, .overwriteInPlace]
        case .package, .folder: [.deleteThenCreate, .swapTemp, .changedInPlace, .changedSwapped]
        }
    }
}

public enum WriteStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Delete the document, then write it again. Mix's export writer does this.
    case deleteThenCreate
    /// Write a complete copy beside it, then swap the copy into place.
    case swapTemp
    /// Write the zip's new bytes over the old ones, keeping the same file.
    case overwriteInPlace
    /// Write only the files that changed, over the old ones.
    case changedInPlace
    /// Write only the files that changed, each to a temporary file that is then renamed into place.
    case changedSwapped

    public var id: Self { self }

    public var label: String {
        switch self {
        case .deleteThenCreate: "delete then create"
        case .swapTemp: "swap in a temp copy"
        case .overwriteInPlace: "overwrite in place"
        case .changedInPlace: "changed files, in place"
        case .changedSwapped: "changed files, swapped in"
        }
    }
}

/// One way of writing for all three formats, so they compare like for like.
public enum Writing: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Delete the mix, then write it again. What Mix's export writer does.
    case replace
    /// Write a complete new copy beside it, then swap it into place.
    case swap
    /// Keep the same files and write over them: a zip rewrites its bytes, a package or folder
    /// rewrites only the files that changed.
    case inPlace

    public var id: Self { self }

    public func style(for kind: StorageKind) -> WriteStyle {
        switch (self, kind) {
        case (.replace, _): .deleteThenCreate
        case (.swap, _): .swapTemp
        case (.inPlace, .zip): .overwriteInPlace
        case (.inPlace, _): .changedInPlace
        }
    }
}

/// How the saving device hands its edits to iCloud.
public enum SyncMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Save and let the system decide when to upload.
    case system
    /// Save, then ask for an upload right away.
    case uploadNow
    /// Pause sync for the whole run, upload after each save failing on conflict, resume at the end.
    case paused

    public var id: Self { self }

    public var label: String {
        switch self {
        case .system: "system"
        case .uploadNow: "upload after each save"
        case .paused: "paused, upload after each save"
        }
    }
}

/// How the receiving device gets an edit it has been told about.
public enum FetchMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case download
    case fetchLatest

    public var id: Self { self }

    public var label: String {
        switch self {
        case .download: "start download"
        case .fetchLatest: "fetch latest now"
        }
    }
}

/// One thing a person does in the editor. In Mix, each one saves.
public enum Action: String, Codable, CaseIterable, Sendable {
    case create, move, addPhoto, removePhoto, close
}
