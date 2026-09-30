import Foundation
import LabKit
import Network

#if canImport(UIKit)
    import UIKit
#endif

/// Where documents live. iCloud is turned on and off in Settings, never here: the app notices,
/// logs what it finds, and keeps new documents on the device while iCloud is off.
extension Lab {
    func start() async {
        keepAwake()
        try? FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.checkICloud(reason: "iCloud changed while running") }
            }
        }
        watchNetwork()
        await checkICloud(reason: "launch")
        link.start()
    }

    /// Compares the iCloud account with the last launch's, since iOS may quit the app when the
    /// switch in Settings flips, before any notification arrives.
    func checkICloud(reason: String) async {
        let token = FileManager.default.ubiquityIdentityToken
        let tokenData = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) }
        let previous = UserDefaults.standard.data(forKey: Keys.token)
        let account =
            switch (previous, tokenData) {
            case (nil, nil): "iCloud off"
            case (nil, _?): "iCloud on, off or unknown before"
            case (_?, nil): "iCloud off, on before"
            case (let old?, let new?): old == new ? "iCloud on, same account" : "iCloud on, a different account than before"
            }
        UserDefaults.standard.set(tokenData, forKey: Keys.token)

        let container = await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: nil) }.value
        if let container {
            let root = container.appending(path: "Documents", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            UserDefaults.standard.set(root.path, forKey: Keys.lastICloudRoot)
            iCloudRoot = root
            iCloudState = "iCloud on"
            startQuery()
        } else {
            stopQuery()
            iCloudRoot = nil
            iCloudState = token == nil ? "iCloud off" : "iCloud unavailable"
        }
        record("icloud", nil, "\(reason): \(account), container \(container == nil ? "unavailable" : "available")")
        inventory()
        refreshDocuments()
        await advanceSwitchTest()
    }

    /// Logs every document in both places, and when iCloud is off, what is left of the old
    /// container folder on this device.
    func inventory() {
        var lines: [String] = []
        if let iCloudRoot {
            lines += listing(iCloudRoot, label: "iCloud")
        } else if let path = UserDefaults.standard.string(forKey: Keys.lastICloudRoot) {
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: path)
                lines.append("the old iCloud folder still holds \(names.count) items: \(names.sorted().joined(separator: ", "))")
            } catch {
                lines.append("the old iCloud folder: \(Self.describe(error))")
            }
        }
        lines += listing(localRoot, label: "on this device")
        for line in lines { record("inventory", nil, line) }
    }

    private func listing(_ root: URL, label: String) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        return ["\(label): \(names.count) items"] + names.map { "  \($0)" }
    }

    /// Both places, merged with what the iCloud query knows about but the folder listing does not.
    func refreshDocuments() {
        var items: [DocumentItem] = []
        func add(_ url: URL, inICloud: Bool) {
            guard let kind = StorageKind(url: url), !items.contains(where: { $0.url == url }) else { return }
            items.append(DocumentItem(url: url, kind: kind, inICloud: inICloud))
        }
        if let iCloudRoot {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: iCloudRoot.path)) ?? [] {
                // A file iOS has not downloaded may be listed as ".Name.labzip.icloud".
                let real = name.hasPrefix(".") && name.hasSuffix(".icloud") ? String(name.dropFirst().dropLast(7)) : name
                add(iCloudRoot.appending(path: real), inICloud: true)
            }
            for url in syncStates.keys { add(url, inICloud: true) }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: localRoot.path)) ?? [] {
            add(localRoot.appending(path: name), inICloud: false)
        }
        documents = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Makes a new mix and saves it once. Returns where it went and its first edit.
    @discardableResult
    func createDocument(_ kind: StorageKind) async -> (url: URL, edit: EditID)? {
        let root = iCloudRoot ?? localRoot
        let title = "\(kind.rawValue) \(Self.fileTime.string(from: .now))"
        let url = root.appending(path: "\(title).\(kind.fileExtension)")
        let style = settings.style(for: kind)
        let edit = nextEdit()
        let content = DocumentContent.new(
            title: title, kind: kind, photos: settings.photos, edit: edit, deviceName: device.name,
            style: style, sync: settings.sync)
        let saved = await save(content, to: url, action: .create, style: style)
        refreshDocuments()
        return saved ? (url, edit) : nil
    }

    /// Moves a document made while iCloud was off into iCloud, the way Mix would.
    @discardableResult
    func moveToICloud(_ item: DocumentItem) async -> Bool {
        guard let iCloudRoot else { return false }
        let source = item.url
        let destination = iCloudRoot.appending(path: item.url.lastPathComponent)
        let start = ContinuousClock.now
        let result = await Task.detached {
            Result { try FileManager.default.setUbiquitous(true, itemAt: source, destinationURL: destination) }
        }.value
        contents[source] = nil
        defer { refreshDocuments() }
        switch result {
        case .success:
            record("moved", item.name, "moved into iCloud in \(Self.ms(since: start))")
            return true
        case .failure(let error):
            record("error", item.name, "moving into iCloud failed: \(Self.describe(error))")
            return false
        }
    }

    /// A summary line for lists.
    func summary(of item: DocumentItem) -> String {
        var parts = [item.kind.rawValue]
        if let state = syncStates[item.url] { parts.append(state.summary) }
        if let stamp = lastStamp[item.url] { parts.append("edit \(stamp.edit)") }
        return parts.joined(separator: ", ")
    }

    private static let fileTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter
    }()

    /// The screen stays on and the Mac stays awake during runs: iOS pauses apps in the
    /// background, and a paused app sees nothing.
    private func keepAwake() {
        #if os(macOS)
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Measuring iCloud sync")
        #else
            UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    /// Network changes explain gaps, and are how the airplane mode conflict test shows up.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet].filter { path.usesInterfaceType($0) }
            let text = path.status == .satisfied ? "online via \(interfaces.map { "\($0)" }.joined(separator: ", "))" : "offline"
            Task { @MainActor in self?.record("network", nil, text) }
        }
        monitor.start(queue: .main)
        networkMonitor = monitor
    }
}
