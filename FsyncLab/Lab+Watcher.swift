import Foundation
import LabKit

/// Watches the container with a metadata query. On the receiving side it notices another
/// device's edit (listed), asks for it, then reads and checks it (readable). It also reports
/// conflict versions, " 2" duplicates, and edits of this device's that went missing.
extension Lab {
    func startQuery() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.notificationBatchingInterval = 0.25
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queryChanged() }
            }
        }
        gathered = false
        query.start()
        self.query = query
    }

    func stopQuery() {
        query?.stop()
        query = nil
        syncStates = [:]
    }

    private func queryChanged() {
        guard let query, let iCloudRoot else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let roots = [iCloudRoot.path, iCloudRoot.resolvingSymlinksInPath().path].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var states: [URL: SyncState] = [:]
        var files: [URL: [URL]] = [:]
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                let root = roots.first(where: { url.path.hasPrefix($0) }),
                let top = url.path.dropFirst(root.count).split(separator: "/").first
            else { continue }
            let doc = iCloudRoot.appending(path: String(top))
            guard StorageKind(url: doc) != nil else { continue }
            states[doc, default: SyncState()].add(item)
            files[doc, default: []].append(url)
        }
        if !gathered {
            gathered = true
            baseline.formUnion(states.keys)
        }
        let previous = syncStates
        syncStates = states
        itemURLs = files
        for (doc, state) in states { react(doc, state, previous[doc]) }
        for doc in previous.keys where states[doc] == nil {
            record("removed", name(of: doc), "no longer listed in iCloud")
        }
        refreshDocuments()
    }

    private func react(_ doc: URL, _ state: SyncState, _ previous: SyncState?) {
        let name = name(of: doc)
        if let error = state.uploadError, error != previous?.uploadError { record("upload error", name, error) }
        if let error = state.downloadError, error != previous?.downloadError { record("download error", name, error) }
        if state.conflicts, previous?.conflicts != true { Task { await inspectConflicts(doc) } }

        let changed =
            previous == nil || state.changedAt != previous?.changedAt || state.bytes != previous?.bytes
            || state.files != previous?.files || (state.download != .current && previous?.download == .current)
        let justSavedHere = ownSaveAt[doc].map { Date.now.timeIntervalSince($0) < 3 } ?? false
        let fromElsewhere = changed && !(justSavedHere && state.download == .current)
        if fromElsewhere {
            // Every change is kept, so each edit's seen time is the first change after its save.
            changeTimes[doc, default: []].append(.now)
            if changeTimes[doc, default: []].count > 300 { changeTimes[doc]?.removeFirst(100) }
        }
        if fromElsewhere, pendingListed[doc] == nil {
            pendingListed[doc] = .now
            record("listed", name, previous == nil ? "appeared: \(state.summary)" : "changed: \(state.summary)")
        }
        guard pendingListed[doc] != nil else { return }
        if state.download == .current {
            Task { await readArrival(doc) }
        } else if !downloadRequested.contains(doc) {
            downloadRequested.insert(doc)
            Task { await requestLatest(doc) }
        }
    }

    /// iOS does not download another device's edit on its own; the app has to ask.
    func requestLatest(_ doc: URL, quietly: Bool = false) async {
        switch settings.fetch {
        case .download: startDownload(doc, quietly: quietly)
        case .fetchLatest: await fetchLatest(doc)
        }
    }

    func startDownload(_ doc: URL, quietly: Bool = false) {
        let targets = StorageKind(url: doc) == .folder ? [doc] + (itemURLs[doc] ?? []) : [doc]
        var refusals: [String] = []
        for target in targets {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: target)
            } catch {
                refusals.append(Self.describe(error))
            }
        }
        guard !quietly || !refusals.isEmpty else { return }
        record(
            "download", name(of: doc),
            "asked for \(targets.count) \(targets.count == 1 ? "item" : "items")"
                + (refusals.first.map { ", \(refusals.count) refused: \($0)" } ?? ""))
    }

    /// Reads a document and checks it. An edit from another device that reads back whole and
    /// consistent becomes readable here, with every edit in its history it brought. Called when the
    /// metadata says the document is current, and every few seconds while an edit announced over
    /// the link has not arrived, since folders and packages do not always say.
    func readArrival(_ doc: URL) async {
        guard let kind = StorageKind(url: doc), !reading.contains(doc) else { return }
        reading.insert(doc)
        defer { reading.remove(doc) }
        let name = name(of: doc)
        let start = ContinuousClock.now
        let read = await Task.detached { DocumentReader.read(doc, kind: kind) }.value
        let now = Date.now
        // A stray file, such as a conflict copy inside a folder, is noted but does not block.
        let strays = read.problems.filter { $0.hasPrefix("unexpected ") }
        let blocking = read.problems.filter { !$0.hasPrefix("unexpected ") }
        guard let stamp = read.stamp, blocking.isEmpty else {
            // Often a folder caught mid download. Said once, then counted until it reads clean.
            if readRetries[doc] == nil {
                let edit = read.stamp?.edit
                // With no mix.json there is no stamp, so the newest edit announced is the one caught
                // half written, once the document has read whole here (a new one starts empty).
                let caught = edit ?? (lastStamp[doc] == nil ? nil : (expected[doc] ?? []).subtracting(readEdits).max())
                record(
                    "inconsistent", name, "\(edit?.description ?? "no stamp"): \(blocking.joined(separator: "; "))",
                    facts: caught.map { [Fact(.problem, edit: $0, document: name, at: now, device: device.id, note: "read: \(blocking.first ?? "")")] } ?? [])
            }
            readRetries[doc, default: 0] += 1
            return
        }
        if let tries = readRetries.removeValue(forKey: doc) {
            record("consistent", name, "read clean after \(tries) inconsistent \(tries == 1 ? "read" : "reads")")
        }
        pendingListed[doc] = nil
        downloadRequested.remove(doc)
        lastStamp[doc] = stamp
        noteDocumentID(stamp.documentID, at: doc)
        if !strays.isEmpty { record("stray", name, strays.joined(separator: "; ")) }
        if baseline.remove(doc) != nil {
            readEdits.formUnion(stamp.history.map(\.edit))
            record("baseline", name, "found at \(stamp.edit) from \(stamp.deviceName), \(stamp.history.count) edits; not timed")
            return
        }
        let madeElsewhere = stamp.edit.device != device.id
        if madeElsewhere { staleContents.insert(doc) }
        let arrivals = stamp.history.filter { $0.edit.device != device.id && !readEdits.contains($0.edit) }
        guard !arrivals.isEmpty else { return }
        var facts: [Fact] = []
        for record in arrivals {
            let latest = record.edit == stamp.edit
            facts.append(
                Fact(
                    .saved, edit: record.edit, document: name, at: record.at, device: record.edit.device, storage: kind,
                    style: latest ? stamp.style : nil, sync: latest ? stamp.sync : nil))
            // Seen is the first change the metadata reported after the save. None means it never
            // reported one, and the edit was found by chasing.
            let savedHere = record.at.addingTimeInterval(-(offsets[record.edit.device] ?? 0))
            if let seen = changeTimes[doc]?.first(where: { $0 >= savedHere }) {
                facts.append(Fact(.listed, edit: record.edit, document: name, at: seen, device: device.id))
            }
            facts.append(Fact(.readable, edit: record.edit, document: name, at: now, device: device.id))
        }
        readEdits.formUnion(arrivals.map(\.edit))
        record(
            "readable", name,
            "\(stamp.edit) from \(stamp.deviceName), \(arrivals.count) new \(arrivals.count == 1 ? "edit" : "edits"), \(Self.bytes(read.byteCount)) read and checked in \(Self.ms(since: start))",
            facts: facts)
        if madeElsewhere { checkOwnEdits(doc, in: stamp) }
    }

    /// Another device announced a save over the link. Keep asking for the document and reading
    /// it until that edit is here, whatever the metadata says, and say so if it never comes.
    func expectArrival(of fact: Fact) {
        guard fact.kind == .saved, fact.device != device.id, !readEdits.contains(fact.edit),
            Date.now.timeIntervalSince(fact.at) < 600, let kind = fact.storage, let iCloudRoot
        else { return }
        let doc = iCloudRoot.appending(path: "\(fact.document).\(kind.fileExtension)")
        expected[doc, default: []].insert(fact.edit)
        guard chasers[doc] == nil else { return }
        chasers[doc] = Task { await chase(doc) }
    }

    private func chase(_ doc: URL) async {
        var asked = Date.distantPast
        var lastProgress = Date.now
        while iCloudRoot != nil, Date.now.timeIntervalSince(lastProgress) < 300 {
            let waiting = (expected[doc] ?? []).subtracting(readEdits)
            if waiting.isEmpty { break }
            if Date.now.timeIntervalSince(asked) > 10 {
                asked = .now
                await requestLatest(doc, quietly: true)
            }
            try? await Task.sleep(for: .seconds(2))
            let before = readEdits.count
            await readArrival(doc)
            if readEdits.count > before { lastProgress = .now }
        }
        let never = (expected[doc] ?? []).subtracting(readEdits).sorted()
        if !never.isEmpty {
            record(
                "missing", name(of: doc), "never became readable here: \(never.map(\.description).joined(separator: ", "))",
                facts: never.map { Fact(.problem, edit: $0, document: name(of: doc), at: .now, device: device.id, note: "never readable here") })
        }
        expected[doc] = nil
        chasers[doc] = nil
    }

    /// After reading a version made elsewhere: is every edit this device made to the document in it?
    func checkOwnEdits(_ doc: URL, in stamp: Stamp) {
        let name = name(of: doc)
        let present = Set(stamp.history.map(\.edit))
        let mine = Set(facts.values.filter { $0.kind == .saved && $0.device == device.id && $0.document == name }.map(\.edit))
        let missing = mine.subtracting(present).subtracting(reportedMissing).sorted()
        guard !missing.isEmpty else { return }
        reportedMissing.formUnion(missing)
        record(
            "missing", name,
            "not in \(stamp.edit) from \(stamp.deviceName): \(missing.map(\.description).joined(separator: ", ")). Looking for conflict versions.",
            facts: missing.map { Fact(.problem, edit: $0, document: name, at: .now, device: device.id, note: "not in \(stamp.edit)") })
        Task { await inspectConflicts(doc) }
    }

    /// The button: reads the current version and checks this device's edits against it again.
    func checkEdits(_ doc: URL) async {
        guard let kind = StorageKind(url: doc) else { return }
        let read = await Task.detached { DocumentReader.read(doc, kind: kind) }.value
        guard let stamp = read.stamp else {
            record("check", name(of: doc), "cannot read: \(read.problems.joined(separator: "; "))")
            return
        }
        reportedMissing = reportedMissing.filter { $0.device != device.id }
        record(
            "check", name(of: doc),
            "current is \(stamp.edit), \(stamp.history.count) edits in history" + (read.problems.isEmpty ? "" : ", problems: \(read.problems.joined(separator: "; "))"))
        checkOwnEdits(doc, in: stamp)
        await inspectConflicts(doc)
    }

    /// Lists the conflict versions iCloud kept and reads the stamp in each.
    func inspectConflicts(_ doc: URL) async {
        guard let kind = StorageKind(url: doc) else { return }
        let name = name(of: doc)
        let targets = kind == .folder ? (itemURLs[doc] ?? []) : [doc]
        var found: [ConflictInfo] = []
        for target in targets {
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: target) ?? [] {
                let versionURL = version.url
                let file = kind == .folder ? String(target.path.dropFirst(doc.path.count + 1)) : ""
                var stamp: Stamp?
                if kind != .folder {
                    stamp = await Task.detached { DocumentReader.read(versionURL, kind: kind, coordinated: false).stamp }.value
                } else if file == DocumentContent.Path.mix {
                    stamp = DocumentReader.stamp(inMixJSON: versionURL)
                }
                found.append(
                    ConflictInfo(
                        id: versionURL.path, file: file, savedBy: version.localizedNameOfSavingComputer ?? "unknown",
                        modified: version.modificationDate, edit: stamp?.edit, history: stamp?.history.map(\.edit) ?? []))
            }
        }
        conflicts[doc] = found
        for info in found {
            record(
                "conflict", name,
                "\(info.file.isEmpty ? "the document" : info.file): a version saved by \(info.savedBy) holds \(info.edit?.description ?? "no stamp")")
        }
        let kept = Set(found.flatMap(\.history)).intersection(reportedMissing).sorted()
        if !kept.isEmpty {
            record(
                "conflict", name, "kept in a conflict version: \(kept.map(\.description).joined(separator: ", "))",
                facts: kept.map { Fact(.problem, edit: $0, document: name, at: .now, device: device.id, note: "kept as a conflict version") })
        }
    }

    /// Keeps the current version and removes the others, so the next run starts clean.
    func keepCurrent(_ doc: URL) {
        let targets = StorageKind(url: doc) == .folder ? (itemURLs[doc] ?? []) : [doc]
        for target in targets {
            do {
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: target) ?? [] { version.isResolved = true }
                try NSFileVersion.removeOtherVersionsOfItem(at: target)
            } catch {
                record("error", name(of: doc), "resolving failed: \(Self.describe(error))")
            }
        }
        conflicts[doc] = []
        record("resolved", name(of: doc), "kept the current version and removed the others")
    }

    /// A " 2" copy carries the same document id inside as the original.
    func noteDocumentID(_ id: UUID, at doc: URL) {
        if documentIDs[doc] == nil, let original = documentIDs.first(where: { $0.value == id && $0.key != doc })?.key {
            record("duplicate", name(of: doc), "is a copy of \(original.lastPathComponent)")
        }
        documentIDs[doc] = id
    }
}
