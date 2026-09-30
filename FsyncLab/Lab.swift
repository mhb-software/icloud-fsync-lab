import Foundation
import LabKit
import Network
import Observation

/// Everything the app knows and does: this device, where documents live, the log and results,
/// what iCloud reports, and the runner. Each concern lives in its own `Lab+` file.
@Observable
final class Lab {
    enum Keys {
        static let device = "device"
        static let settings = "settings"
        static let editCounter = "editCounter"
        static let token = "iCloudToken"
        static let lastICloudRoot = "lastICloudRoot"
        static let outcomes = "outcomes"
        static let speedRuns = "speedRuns"
    }

    // MARK: This device

    var device: DeviceIdentity {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(device), forKey: Keys.device) }
    }
    var settings: RunSettings {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Keys.settings) }
    }
    @ObservationIgnored var awakeActivity: (any NSObjectProtocol)?
    @ObservationIgnored var networkMonitor: NWPathMonitor?

    // MARK: Log and results

    var entries: [LogEntry] = []
    var facts: [UUID: Fact] = [:]
    @ObservationIgnored var peerFactIDs: Set<UUID> = []
    /// Seconds each other device's clock is ahead of this one's, from the link.
    var offsets: [String: Double] = [:]
    var names: [String: String] = [:]
    @ObservationIgnored var logHandle: FileHandle?

    // MARK: Where documents live

    var iCloudRoot: URL?
    var iCloudState = "checking iCloud"
    let localRoot: URL
    var documents: [DocumentItem] = []

    // MARK: What iCloud reports

    @ObservationIgnored var query: NSMetadataQuery?
    var syncStates: [URL: SyncState] = [:]
    var lastStamp: [URL: Stamp] = [:]
    var conflicts: [URL: [ConflictInfo]] = [:]
    var controls: [URL: String] = [:]
    @ObservationIgnored var itemURLs: [URL: [URL]] = [:]
    @ObservationIgnored var pendingListed: [URL: Date] = [:]
    @ObservationIgnored var downloadRequested: Set<URL> = []
    @ObservationIgnored var reading: Set<URL> = []
    @ObservationIgnored var ownSaveAt: [URL: Date] = [:]
    @ObservationIgnored var readEdits: Set<EditID> = []
    @ObservationIgnored var reportedMissing: Set<EditID> = []
    @ObservationIgnored var documentIDs: [URL: UUID] = [:]
    @ObservationIgnored var pendingUploads: [URL: [EditID]] = [:]
    @ObservationIgnored var uploadSaveTime: [URL: Date] = [:]
    @ObservationIgnored var uploadWatch: [URL: Task<Void, Never>] = [:]
    /// Documents found when the query first gathers: read once without timing, since their
    /// edits arrived while the app was closed.
    @ObservationIgnored var baseline: Set<URL> = []
    @ObservationIgnored var gathered = false
    @ObservationIgnored var readRetries: [URL: Int] = [:]
    /// Edits other devices announced over the link that have not been read here yet.
    @ObservationIgnored var expected: [URL: Set<EditID>] = [:]
    @ObservationIgnored var chasers: [URL: Task<Void, Never>] = [:]
    /// When the metadata reported each change made elsewhere, per document.
    @ObservationIgnored var changeTimes: [URL: [Date]] = [:]

    // MARK: The runner

    var running: URL?
    /// What a test on the main screen is doing right now, in words.
    var progress: String?
    /// The test running on any linked device. While set, every device shows the running screen.
    var activeTest: TestStatus?
    var isBusy: Bool { running != nil || progress != nil || activeTest.map { !$0.finished } ?? false }
    var switchTest: SwitchTest? {
        didSet { saveSwitchTest() }
    }
    /// Where Save logs puts its files, by name, once one has been chosen.
    var exportFolderName: String?
    /// Conflict and iCloud test outcomes, one per format, for the comparison grid.
    var outcomes: [TestOutcome] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(outcomes), forKey: Keys.outcomes) }
    }
    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored var contents: [URL: DocumentContent] = [:]
    @ObservationIgnored var staleContents: Set<URL> = []

    // MARK: The other device

    let link = PeerLink()

    init() {
        let defaults = UserDefaults.standard
        let device =
            defaults.data(forKey: Keys.device).flatMap { try? JSONDecoder().decode(DeviceIdentity.self, from: $0) }
            ?? DeviceIdentity(name: Self.defaultDeviceName)
        // didSet does not run in init, so a new identity is saved here, or every launch makes another.
        defaults.set(try? JSONEncoder().encode(device), forKey: Keys.device)
        self.device = device
        settings =
            defaults.data(forKey: Keys.settings).flatMap { try? JSONDecoder().decode(RunSettings.self, from: $0) }
            ?? RunSettings()
        localRoot = URL.documentsDirectory.appending(path: "On this device", directoryHint: .isDirectory)
        link.lab = self
        loadLog()
        switchTest = loadSwitchTest()
        if let test = switchTest, test.step != .done {
            // iOS may have quit the app when the iCloud switch flipped: pick the test back up.
            var status = TestStatus(test: .iCloud, startedBy: device, sync: settings.sync, step: test.step.instruction)
            status.documents = test.mixes.map { URL(filePath: $0.file).deletingPathExtension().lastPathComponent }
            activeTest = status
        }
        outcomes =
            defaults.data(forKey: Keys.outcomes).flatMap { try? JSONDecoder().decode([TestOutcome].self, from: $0) } ?? []
        exportFolderName = exportFolder()?.lastPathComponent
    }

    /// Edit numbers only ever go up on a device, so an edit lost in a conflict is never reused.
    func nextEdit() -> EditID {
        let number = UserDefaults.standard.integer(forKey: Keys.editCounter) + 1
        UserDefaults.standard.set(number, forKey: Keys.editCounter)
        return EditID(device: device.id, number: number)
    }

    func name(of doc: URL) -> String { doc.deletingPathExtension().lastPathComponent }

    func isInICloud(_ doc: URL) -> Bool {
        guard let iCloudRoot else { return false }
        return doc.path.hasPrefix(iCloudRoot.path)
    }

    static var defaultDeviceName: String {
        #if os(macOS)
            "Mac"
        #else
            UIDevice.current.model
        #endif
    }

    nonisolated static func describe(_ error: any Error) -> String {
        let error = error as NSError
        var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code))"
        }
        return text
    }

    nonisolated static func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }
    nonisolated static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = (ContinuousClock.now - start).components
        return ms(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    nonisolated static func bytes(_ count: Int) -> String { count.formatted(.byteCount(style: .file)) }
}

#if canImport(UIKit)
    import UIKit
#endif

/// A document in one of the two places documents live.
struct DocumentItem: Identifiable, Hashable {
    var url: URL
    var kind: StorageKind
    var inICloud: Bool

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// What iCloud's metadata says about one document, summed over its files.
struct SyncState: Equatable {
    enum Download: Int, Comparable {
        case notDownloaded, stale, current

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var uploaded = true
    var uploading = false
    var download = Download.current
    var downloading = false
    var conflicts = false
    var changedAt: Date?
    var bytes = 0
    var files = 0
    var uploadError: String?
    var downloadError: String?

    mutating func add(_ item: NSMetadataItem) {
        func value<T>(_ key: String) -> T? { item.value(forAttribute: key) as? T }
        files += 1
        bytes += value(NSMetadataItemFSSizeKey) ?? 0
        // A plain subfolder reports sync states of its own that never settle; only files and
        // packages speak for the document.
        if value(NSMetadataItemContentTypeKey) == "public.folder" { return }
        if value(NSMetadataUbiquitousItemIsUploadedKey) == false { uploaded = false }
        if value(NSMetadataUbiquitousItemIsUploadingKey) == true { uploading = true }
        if value(NSMetadataUbiquitousItemIsDownloadingKey) == true { downloading = true }
        if value(NSMetadataUbiquitousItemHasUnresolvedConflictsKey) == true { conflicts = true }
        if let status: String = value(NSMetadataUbiquitousItemDownloadingStatusKey) {
            let itemDownload: Download =
                status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                ? .current : status == NSMetadataUbiquitousItemDownloadingStatusDownloaded ? .stale : .notDownloaded
            download = min(download, itemDownload)
        }
        if let date: Date = value(NSMetadataItemFSContentChangeDateKey) { changedAt = max(changedAt ?? date, date) }
        if let error: NSError = value(NSMetadataUbiquitousItemUploadingErrorKey) { uploadError = Lab.describe(error) }
        if let error: NSError = value(NSMetadataUbiquitousItemDownloadingErrorKey) { downloadError = Lab.describe(error) }
    }

    var summary: String {
        var parts = [uploading ? "uploading" : uploaded ? "uploaded" : "not uploaded"]
        switch download {
        case .current: parts.append(downloading ? "downloading" : "current")
        case .stale: parts.append(downloading ? "downloading" : "out of date")
        case .notDownloaded: parts.append(downloading ? "downloading" : "not downloaded")
        }
        if conflicts { parts.append("conflict") }
        parts.append("\(Lab.bytes(bytes)) in \(files) \(files == 1 ? "item" : "items")")
        return parts.joined(separator: ", ")
    }
}

/// One conflict version iCloud kept, and what the stamp inside it says.
struct ConflictInfo: Identifiable, Hashable {
    var id: String
    /// The file inside a plain folder, or empty for the whole document.
    var file: String
    var savedBy: String
    var modified: Date?
    var edit: EditID?
    var history: [EditID]
}

/// The runner's choices, remembered between launches.
struct RunSettings: Codable, Equatable {
    var actions = 20
    var shortestPause = 1.0
    var longestPause = 5.0
    var photos = 6
    var sync = SyncMode.system
    var fetch = FetchMode.download
    /// One choice for all three formats, so they are written alike.
    var writing = Writing.inPlace

    func style(for kind: StorageKind) -> WriteStyle { writing.style(for: kind) }
}
