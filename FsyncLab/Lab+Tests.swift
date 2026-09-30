import Foundation
import LabKit

/// One test's answer for one format, short enough for the comparison grid.
struct TestOutcome: Codable, Identifiable {
    enum Test: String, Codable { case conflict, iCloudOff, iCloudOn, movedIn }

    var id = UUID()
    var test: Test
    var kind: StorageKind
    var sync: SyncMode?
    var document: String?
    var at = Date.now
    var short: String
    var detail: String
}

/// The three tests on the main screen. Each runs on a Zip, a Package and a Folder in turn, and
/// every linked device follows along on its own running screen.
extension Lab {
    // MARK: - A test's life

    func beginTest(_ test: TestStatus.Test) {
        var status = TestStatus(test: test, startedBy: device, sync: settings.sync, step: "Starting")
        status.writing = settings.writing
        activeTest = status
        link.send(.test(status))
    }

    /// Says what a test is doing now, here and on every linked device.
    func report(_ step: String, kind: StorageKind? = nil) {
        progress = step
        guard var test = activeTest, test.startedBy.id == device.id, !test.finished else { return }
        test.step = step
        if let kind { test.kind = kind }
        activeTest = test
        link.send(.test(test))
    }

    func addToTest(_ doc: URL) {
        guard var test = activeTest, test.startedBy.id == device.id else { return }
        test.documents.append(name(of: doc))
        activeTest = test
        link.send(.test(test))
    }

    func finishTest(_ step: String) {
        progress = nil
        guard var test = activeTest, test.startedBy.id == device.id else { return }
        test.step = step
        test.finished = true
        activeTest = test
        link.send(.test(test))
    }

    /// Back to the main screen on this device.
    func dismissTest() {
        if activeTest?.test == .iCloud, activeTest?.startedBy.id == device.id { switchTest = nil }
        activeTest = nil
    }

    /// Stop works from any linked device: the device that started the test stops it.
    func stopTest() {
        guard let test = activeTest, !test.finished else { return }
        guard test.startedBy.id == device.id else {
            link.send(.stopTest, to: [test.startedBy.id])
            return
        }
        stop()
        if test.test == .iCloud {
            switchTest = nil
            finishTest("Stopped")
        }
    }

    /// Another device's test, as it reports itself.
    func peerTest(_ status: TestStatus?, from peerID: String?) {
        if let status {
            if status.startedBy.id != device.id { activeTest = status }
        } else if activeTest?.startedBy.id == peerID {
            activeTest = nil
        }
    }

    /// The device running the test went away.
    func peerLost(_ peerID: String) {
        guard var test = activeTest, test.startedBy.id == peerID, !test.finished else { return }
        test.step = "Lost contact with \(test.startedBy.name)"
        test.finished = true
        activeTest = test
    }

    // MARK: - 1. Speed

    /// For each format, a new mix and an editing session on it. The first format rotates from run
    /// to run, and the next one starts only once the linked devices have the last edit, so no
    /// format always goes first or starts while another is still syncing.
    func runEditingTest() {
        guard !isBusy, iCloudRoot != nil else { return }
        beginTest(.speed)
        let run = UserDefaults.standard.integer(forKey: Keys.speedRuns)
        UserDefaults.standard.set(run + 1, forKey: Keys.speedRuns)
        // Folder, package, zip first, then rotated one place each run.
        let kinds = Array(StorageKind.allCases.reversed())
        let order = kinds.indices.map { kinds[(run + $0) % kinds.count] }
        runTask = Task {
            for kind in order where !Task.isCancelled {
                report("Making a new mix", kind: kind)
                guard let (doc, _) = await createDocument(kind) else { continue }
                addToTest(doc)
                await session(on: doc)
                await settle(doc, kind: kind)
            }
            finishTest(Task.isCancelled ? "Stopped" : "Finished")
        }
    }

    /// Waits up to two minutes for every linked device to read the mix's last edit.
    private func settle(_ doc: URL, kind: StorageKind) async {
        let peers = link.connectedPeers
        guard let last = lastStamp[doc]?.edit, !peers.isEmpty else { return }
        report("Waiting for \(peers.map(\.name).joined(separator: " and ")) to get the last edit", kind: kind)
        let deadline = Date.now.addingTimeInterval(120)
        while !Task.isCancelled, Date.now < deadline {
            let waiting = peers.filter { peer in
                !facts.values.contains { $0.kind == .readable && $0.device == peer.id && $0.edit == last }
            }
            if waiting.isEmpty { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - 2. Not losing work

    /// For each format, every linked device edits the same new mix at the same moment.
    func runConflictTest() {
        let peers = link.connectedPeers
        guard !isBusy, iCloudRoot != nil, !peers.isEmpty else { return }
        let sync = settings.sync
        beginTest(.conflict)
        runTask = Task {
            for kind in StorageKind.allCases where !Task.isCancelled {
                await conflictTest(kind, sync: sync, peers: peers)
            }
            running = nil
            finishTest(Task.isCancelled ? "Stopped" : "Finished")
        }
    }

    private func conflictTest(_ kind: StorageKind, sync: SyncMode, peers: [PeerLink.Peer]) async {
        report("Making a new mix", kind: kind)
        guard let (doc, created) = await createDocument(kind) else { return }
        addToTest(doc)
        running = doc
        let name = name(of: doc)
        report("Waiting for \(peers.map(\.name).joined(separator: " and ")) to get it", kind: kind)
        let deadline = Date.now.addingTimeInterval(180)
        var ready: [PeerLink.Peer] = []
        while !Task.isCancelled {
            ready = peers.filter { peer in
                facts.values.contains { $0.kind == .readable && $0.device == peer.id && $0.edit == created }
            }
            if ready.count == peers.count || Date.now > deadline { break }
            try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled else { return }
        guard !ready.isEmpty else {
            outcome(.conflict, kind, sync: sync, document: name, short: "did not run", detail: "no linked device got \(name) within 3 minutes")
            return
        }
        let moment = Date.now.addingTimeInterval(3)
        link.send(.editAt(document: doc.lastPathComponent, at: moment, sync: sync), to: ready.map(\.id))
        report("\(ready.count + 1) devices edit at the same moment", kind: kind)
        await edit(doc, at: moment, sync: sync)
        report("Waiting 90 seconds for iCloud to settle", kind: kind)
        try? await Task.sleep(for: .seconds(90))
        guard !Task.isCancelled else { return }
        let (short, detail) = await conflictOutcome(doc, peers: ready, created: created)
        outcome(.conflict, kind, sync: sync, document: name, short: short, detail: "\(name): \(detail)")
        link.send(.note("conflict test on \(name): \(detail)"))
    }

    /// One edit at a given moment. With paused sync, sync is paused around it, like an open editor.
    func edit(_ doc: URL, at moment: Date, sync: SyncMode) async {
        try? await Task.sleep(for: .seconds(max(0, moment.timeIntervalSinceNow)))
        let paused = sync == .paused
        if paused { await pause(doc) }
        await act(.move, on: doc, sync: sync)
        if paused { await resume(doc, .preserveLocalChanges) }
    }

    /// This device's half of another device's conflict test. The moment is converted to this clock.
    func peerAskedForEdit(document: String, at moment: Date, sync: SyncMode, from peerID: String?) {
        let asker = peerID.flatMap { names[$0] } ?? "The other device"
        guard let iCloudRoot else {
            record("conflict test", nil, "\(asker) asked for an edit to \(document), but iCloud is off here")
            return
        }
        let doc = iCloudRoot.appending(path: document)
        let local = moment.addingTimeInterval(-(peerID.flatMap { offsets[$0] } ?? 0))
        record("conflict test", name(of: doc), "\(asker) asked for an edit at the same moment as its own")
        Task { await edit(doc, at: local, sync: sync) }
    }

    /// Where each device's edit ended up: in the current version, a hidden conflict version,
    /// a separate " 2" file, or nowhere. Returns a grid label and sentences.
    private func conflictOutcome(_ doc: URL, peers: [PeerLink.Peer], created: EditID) async -> (String, String) {
        let name = name(of: doc)
        guard let kind = StorageKind(url: doc) else { return ("did not run", "unknown format") }
        let current = await Task.detached { DocumentReader.read(doc, kind: kind) }.value
        await inspectConflicts(doc)
        let hidden = conflicts[doc] ?? []
        var copies: [(name: String, history: [EditID])] = []
        for item in documents where item.inICloud && item.url != doc && item.name.hasPrefix(name) {
            let url = item.url
            let read = await Task.detached { DocumentReader.read(url, kind: kind) }.value
            if let stamp = read.stamp, stamp.documentID == current.stamp?.documentID ?? stamp.documentID {
                copies.append((item.url.lastPathComponent, stamp.history.map(\.edit)))
            }
        }
        enum Fate { case current, hidden, copy(String), lost }
        func fate(_ edit: EditID) -> Fate {
            if current.stamp?.history.contains(where: { $0.edit == edit }) == true { return .current }
            if hidden.contains(where: { $0.history.contains(edit) }) { return .hidden }
            if let copy = copies.first(where: { $0.history.contains(edit) }) { return .copy(copy.name) }
            return .lost
        }
        var sentences: [String] = []
        var fates: [Fate] = []
        for (id, owner) in [(device.id, device.name)] + peers.map({ ($0.id, $0.name) }) {
            let edit = facts.values.filter { $0.kind == .saved && $0.device == id && $0.document == name && $0.edit != created }
                .map(\.edit).max()
            guard let edit else {
                sentences.append("\(owner) never reported its edit")
                continue
            }
            let where_ = fate(edit)
            fates.append(where_)
            switch where_ {
            case .current: sentences.append("\(owner)'s edit is the current version")
            case .hidden: sentences.append("\(owner)'s edit was kept as a hidden conflict version")
            case .copy(let file): sentences.append("\(owner)'s edit was kept in a separate file, \(file)")
            case .lost: sentences.append("\(owner)'s edit was lost: it is nowhere")
            }
        }
        let mixed = current.problems.contains { !$0.hasPrefix("unexpected ") }
        let lost = fates.filter { if case .lost = $0 { true } else { false } }.count
        let separate = fates.filter { if case .copy = $0 { true } else { false } }.count
        let kept = fates.filter { if case .hidden = $0 { true } else { false } }.count
        let short =
            mixed ? "mixed up"
            : lost > 0 ? (lost == 1 ? "edit lost" : "\(lost) edits lost")
            : separate > 0 ? "\(separate + 1) files"
            : kept > 0 ? (kept == 1 ? "one hidden" : "\(kept) hidden")
            : fates.count > 1 ? "no conflict" : "did not run"
        if short == "no conflict" { sentences = ["no conflict happened: a device got another's edit before saving"] }
        if mixed { sentences.append("the current version mixes files from different edits") }
        return (short, sentences.joined(separator: ". ") + ".")
    }

    func outcome(
        _ test: TestOutcome.Test, _ kind: StorageKind, sync: SyncMode? = nil, document: String? = nil, short: String,
        detail: String
    ) {
        outcomes.append(TestOutcome(test: test, kind: kind, sync: sync, document: document, short: short, detail: detail))
        record("result", document, "\(kind.title), \(test.rawValue): \(detail)")
    }

    // MARK: - The comparison grid

    struct GridRow: Identifiable {
        var label: String
        var cells: [String]
        var id: String { label }
    }

    /// One row per question and one column per format. With `documents`, the numbers of one run
    /// from any device; without, every test run from this device with the chosen upload option and
    /// each format's current write style. Readable gets a row per receiving device.
    func comparison(documents: Set<String>? = nil) -> [GridRow] {
        let kinds = StorageKind.allCases
        let sync = settings.sync
        let rows =
            if let documents {
                self.rows.filter { documents.contains($0.document) }
            } else {
                self.rows.filter { row in
                    row.edit.device == device.id && row.sync == sync && row.style == row.storage.map { settings.style(for: $0) }
                }
            }
        func edits(_ kind: StorageKind) -> [ResultRow] { rows.filter { $0.storage == kind } }
        func median(_ values: [Double]) -> Double? {
            let sorted = values.sorted()
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }
        func seconds(_ value: Double?) -> String? { value.map { String(format: "%.1f s", $0) } }
        let afterLastSave = (documents == nil ? sync : rows.first?.sync ?? sync) == .system
        var grid = [
            GridRow(label: "Save", cells: kinds.map { median(edits($0).compactMap(\.writeSeconds)).map(Lab.ms) ?? "not run" }),
            GridRow(
                label: afterLastSave ? "Upload done" : "Uploaded",
                cells: kinds.map { kind in
                    let all = edits(kind)
                    guard !all.isEmpty else { return "not run" }
                    guard afterLastSave else { return seconds(median(all.compactMap(\.uploaded))) ?? "waiting" }
                    // iCloud only reports uploads done once edits stop, so the number that means
                    // something is how long after each run's last save that happened.
                    let lastSaves = Dictionary(grouping: all, by: \.document).values.compactMap { run in
                        run.max { ($0.savedAt ?? .distantPast) < ($1.savedAt ?? .distantPast) }
                    }
                    if let time = seconds(median(lastSaves.compactMap(\.uploaded))) { return time }
                    // A package written in place never shows as pending on iOS, so there is nothing to time.
                    return lastSaves.contains { $0.notes.contains { $0.hasPrefix("upload:") } } ? "not shown" : "waiting"
                }),
        ]
        let receivers = Set(rows.flatMap { $0.arrivals.map(\.device) }).sorted { deviceName($0) < deviceName($1) }
        if receivers.isEmpty {
            grid.append(GridRow(label: "Readable", cells: kinds.map { edits($0).isEmpty ? "not run" : "waiting" }))
        }
        for receiver in receivers {
            grid.append(
                GridRow(
                    label: "Readable on \(deviceName(receiver))",
                    cells: kinds.map { kind in
                        let all = edits(kind).filter { $0.edit.device != receiver }
                        guard !all.isEmpty else { return "not run" }
                        let times = all.compactMap { row in row.arrivals.first { $0.device == receiver }?.readable }
                        guard let time = seconds(median(times)) else { return "waiting" }
                        return times.count == all.count ? time : "\(time), \(times.count)/\(all.count)"
                    }))
        }
        grid.append(
            GridRow(
                label: "Half updated",
                cells: kinds.map { kind in
                    let all = edits(kind)
                    guard !all.isEmpty else { return "not run" }
                    let torn = all.filter { $0.notes.contains { $0.hasPrefix("read:") } }.count
                    return torn == 0 ? "never" : "\(torn) of \(all.count)"
                }))
        func latest(_ test: TestOutcome.Test, _ kind: StorageKind) -> String? {
            outcomes.last { outcome in
                outcome.test == test && outcome.kind == kind
                    && (documents.map { outcome.document.map($0.contains) ?? false } ?? (test != .conflict || outcome.sync == sync))
            }?.short
        }
        let outcomeRows: [(String, TestOutcome.Test)] = [
            ("Conflict", .conflict), ("iCloud off", .iCloudOff), ("Back on", .iCloudOn), ("Moved in", .movedIn),
        ]
        for (label, test) in outcomeRows {
            let cells = kinds.map { latest(test, $0) }
            if documents == nil || cells.contains(where: { $0 != nil }) {
                grid.append(GridRow(label: label, cells: cells.map { $0 ?? "not run" }))
            }
        }
        return grid
    }

    func deviceName(_ id: String) -> String {
        id == device.id ? device.name : names[id] ?? id
    }
}

extension StorageKind {
    var title: String {
        switch self {
        case .zip: "Zip"
        case .package: "Package"
        case .folder: "Folder"
        }
    }
}

extension Writing {
    var title: String {
        switch self {
        case .replace: "Replace"
        case .swap: "Swap"
        case .inPlace: "In place"
        }
    }

    var explanation: String {
        switch self {
        case .replace: "Delete the mix, then write it again. What Mix's export writer does."
        case .swap: "Write a complete new copy beside it, then swap it into place."
        case .inPlace:
            "Keep the same files and write over them. A zip rewrites the whole file; a package or folder rewrites only the files that changed."
        }
    }
}

extension SyncMode {
    var title: String {
        switch self {
        case .system: "iCloud decides"
        case .uploadNow: "Upload now"
        case .paused: "Paused"
        }
    }

    var explanation: String {
        switch self {
        case .system: "iCloud uploads whenever it decides to."
        case .uploadNow: "The app asks iCloud to upload after every save."
        case .paused: "Sync is paused while editing. Each save uploads at once, and a newer version in iCloud is caught instead of overwritten."
        }
    }
}

extension TestStatus.Test {
    var title: String {
        switch self {
        case .speed: "Speed"
        case .conflict: "Not losing work"
        case .iCloud: "iCloud off and on"
        }
    }
}
