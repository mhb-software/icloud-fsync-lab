import Foundation
import LabKit

/// The third test: what happens to mixes when iCloud is switched off for this app in Settings,
/// and switched back on with mixes made while it was off, for each format. iOS may quit the app
/// when the switch flips, so the test's progress is saved as it goes.
struct SwitchTest: Codable, Equatable {
    enum Step: String, Codable {
        case waitingForOff, waitingForOn, done

        var instruction: String {
            switch self {
            case .waitingForOff:
                "Turn off iCloud Drive for fsync Lab in Settings (your name, then iCloud, then iCloud Drive), then come back here."
            case .waitingForOn: "Turn iCloud Drive back on for fsync Lab in Settings, then come back here."
            case .done: "Finished"
            }
        }
    }

    struct Mix: Codable, Equatable {
        var file: String
        /// Its latest edit when iCloud was about to be turned off.
        var edit: EditID?
        /// Whether iCloud said it was fully uploaded then.
        var uploaded: Bool

        var kind: StorageKind { StorageKind(url: URL(filePath: file)) ?? .zip }
    }

    var step: Step
    var mixes: [Mix]
    /// The iCloud Documents folder when the test started.
    var root: String
    var madeWhileOff: [String] = []
    var report: [String] = []
}

extension Lab {
    static let switchTestKey = "switchTest"

    func loadSwitchTest() -> SwitchTest? {
        UserDefaults.standard.data(forKey: Self.switchTestKey).flatMap { try? JSONDecoder().decode(SwitchTest.self, from: $0) }
    }

    func saveSwitchTest() {
        UserDefaults.standard.set(switchTest.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.switchTestKey)
    }

    /// Makes a new mix of each format and edits each once, so there is fresh work in flight when
    /// iCloud goes off.
    func startSwitchTest() {
        guard let iCloudRoot, !isBusy else { return }
        beginTest(.iCloud)
        runTask = Task {
            var mixes: [SwitchTest.Mix] = []
            for kind in StorageKind.allCases where !Task.isCancelled {
                report("Making a new mix", kind: kind)
                guard let (doc, _) = await createDocument(kind) else { continue }
                addToTest(doc)
                report("Editing it", kind: kind)
                await act(.move, on: doc)
                let state = syncStates[doc]
                mixes.append(
                    .init(file: doc.lastPathComponent, edit: lastStamp[doc]?.edit, uploaded: state.map { $0.uploaded && !$0.uploading } ?? false))
            }
            guard !Task.isCancelled else { return }
            let test = SwitchTest(step: .waitingForOff, mixes: mixes, root: iCloudRoot.path)
            switchTest = test
            record("icloud test", nil, "made and edited \(mixes.map(\.file).joined(separator: ", "))")
            report(test.step.instruction)
        }
    }

    /// Moves the test along after each iCloud check.
    func advanceSwitchTest() async {
        guard var test = switchTest else { return }
        if test.step == .waitingForOff, iCloudRoot == nil {
            test.report = offReport(test)
            test.step = .waitingForOn
            switchTest = test
            report(test.step.instruction)
        } else if test.step == .waitingForOn, iCloudRoot != nil {
            report("iCloud is back on. Checking the mixes")
            let deadline = Date.now.addingTimeInterval(60)
            while !gathered, Date.now < deadline { try? await Task.sleep(for: .seconds(1)) }
            try? await Task.sleep(for: .seconds(5))
            test.report += await onReport(test)
            test.step = .done
            switchTest = test
            finishTest("Finished")
        }
    }

    /// While iCloud is off, new mixes land on this device: one of each format.
    func makeMixesWhileOff() async {
        guard iCloudRoot == nil, var test = switchTest else { return }
        for kind in StorageKind.allCases {
            guard let (url, _) = await createDocument(kind) else { continue }
            test.madeWhileOff.append(url.lastPathComponent)
            addToTest(url)
        }
        test.report.append("Made \(test.madeWhileOff.count) mixes on this device while iCloud was off.")
        switchTest = test
    }

    func moveAllIntoICloud() async {
        guard var test = switchTest else { return }
        for item in documents where !item.inICloud {
            let moved = await moveToICloud(item)
            outcome(
                .movedIn, item.kind, document: item.name, short: moved ? "moved" : "failed",
                detail: "\(item.name) \(moved ? "moved into iCloud" : "could not move into iCloud; see the log")")
            test.report.append("\(item.kind.title) \(moved ? "moved into iCloud" : "failed to move into iCloud").")
        }
        switchTest = test
    }

    private func offReport(_ test: SwitchTest) -> [String] {
        let fileManager = FileManager.default
        var lines = ["iCloud turned off."]
        for mix in test.mixes {
            let path = (test.root as NSString).appendingPathComponent(mix.file)
            let short: String
            let sentence: String
            if !fileManager.fileExists(atPath: path) {
                (short, sentence) = ("gone", "is gone from this device")
            } else if fileManager.isReadableFile(atPath: path) {
                (short, sentence) = ("still here", "is still on this device")
            } else {
                (short, sentence) = ("unreadable", "is still here but cannot be read")
            }
            let pending = mix.uploaded ? "" : ", and its last edit had not finished uploading"
            let name = URL(filePath: mix.file).deletingPathExtension().lastPathComponent
            outcome(.iCloudOff, mix.kind, document: name, short: short, detail: "\(mix.file) \(sentence)\(pending)")
            lines.append("\(mix.kind.title) \(sentence)\(pending).")
        }
        return lines
    }

    private func onReport(_ test: SwitchTest) async -> [String] {
        guard let iCloudRoot else { return [] }
        var lines = ["iCloud turned back on."]
        for mix in test.mixes {
            let url = iCloudRoot.appending(path: mix.file)
            let short: String
            let sentence: String
            if syncStates[url] == nil, !documents.contains(where: { $0.url == url }) {
                (short, sentence) = ("not back", "is not in iCloud")
            } else if syncStates[url]?.download != .current {
                startDownload(url)
                (short, sentence) = ("not downloaded", "is back but not downloaded yet, so its edit is unchecked")
            } else {
                let kind = mix.kind
                let history = await Task.detached { DocumentReader.read(url, kind: kind).stamp?.history.map(\.edit) }.value ?? []
                if let edit = mix.edit, !history.contains(edit) {
                    (short, sentence) = ("edit lost", "is back, but its last edit \(edit) is gone")
                } else {
                    (short, sentence) = ("kept", "is back with its last edit")
                }
            }
            outcome(.iCloudOn, mix.kind, document: name(of: url), short: short, detail: "\(mix.file) \(sentence)")
            lines.append("\(mix.kind.title) \(sentence).")
        }
        if documents.contains(where: { !$0.inICloud }) {
            lines.append("Mixes made while iCloud was off are still on this device only.")
        }
        return lines
    }
}
