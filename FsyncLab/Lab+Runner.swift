import Foundation
import LabKit

/// Saves the way Mix does: one save after every action, at a person's pace.
extension Lab {
    func perform(_ action: Action, on item: DocumentItem) {
        guard !isBusy else { return }
        running = item.url
        runTask = Task {
            await act(action, on: item.url)
            running = nil
        }
    }

    func runSession(on item: DocumentItem) {
        guard !isBusy else { return }
        runTask = Task { await session(on: item.url) }
    }

    /// Some actions a few seconds apart, then closing the editor. With the paused sync mode,
    /// sync is paused for the whole session and resumed at the end, as an open document would be.
    func session(on doc: URL) async {
        running = doc
        defer {
            running = nil
            progress = nil
        }
        let settings = settings
        let name = name(of: doc)
        record(
            "run", name,
            "\(settings.actions) edits, \(settings.shortestPause) to \(settings.longestPause) s apart, \(settings.style(for: StorageKind(url: doc) ?? .zip).label), sync \(settings.sync.label)")
        let paused = settings.sync == .paused && isInICloud(doc)
        if paused { await pause(doc) }
        var done = 0
        while done < settings.actions, !Task.isCancelled {
            report("Edit \(done + 1) of \(settings.actions)")
            await act(Self.randomAction(), on: doc)
            done += 1
            if done < settings.actions {
                try? await Task.sleep(for: .seconds(Double.random(in: settings.shortestPause...settings.longestPause)))
            }
        }
        report("Closing the mix")
        await act(.close, on: doc)
        if paused { await resume(doc, .preserveLocalChanges) }
        record("run", name, done < settings.actions ? "stopped after \(done) edits" : "finished")
    }

    func stop() { runTask?.cancel() }

    /// Mostly repositioning, now and then a photo added or removed.
    static func randomAction() -> Action {
        switch Int.random(in: 0..<100) {
        case 0..<85: .move
        case 85..<93: .addPhoto
        default: .removePhoto
        }
    }

    /// One action and its save. `edit` is passed when redoing an edit on top of a newer version.
    @discardableResult
    func act(_ action: Action, on doc: URL, edit: EditID? = nil, sync: SyncMode? = nil, attempt: Int = 1) async -> Bool {
        guard let kind = StorageKind(url: doc) else { return false }
        var content: DocumentContent
        if let cached = contents[doc], !staleContents.contains(doc) {
            content = cached
        } else {
            let read = await Task.detached { DocumentReader.read(doc, kind: kind) }.value
            guard let loaded = read.content else {
                record("error", name(of: doc), "cannot load before \(action.rawValue): \(read.problems.joined(separator: "; "))")
                return false
            }
            content = loaded
        }
        let style = settings.style(for: kind)
        content.apply(action, edit: edit ?? nextEdit(), deviceName: device.name, style: style, sync: sync ?? settings.sync)
        return await save(content, to: doc, action: action, style: style, attempt: attempt)
    }

    @discardableResult
    func save(_ content: DocumentContent, to doc: URL, action: Action, style: WriteStyle, attempt: Int = 1) async -> Bool {
        let name = name(of: doc)
        let stamp = content.stamp
        let result = await Task.detached { Result { try DocumentWriter.write(content, to: doc, style: style) } }.value
        let report: WriteReport
        switch result {
        case .success(let value): report = value
        case .failure(let error):
            record("error", name, "\(stamp.edit) \(action.rawValue) did not save: \(Self.describe(error))")
            return false
        }
        contents[doc] = content
        staleContents.remove(doc)
        ownSaveAt[doc] = .now
        lastStamp[doc] = stamp
        noteDocumentID(content.documentID, at: doc)
        record(
            "saved", name,
            "\(stamp.edit) \(action.rawValue), \(style.label): \(Self.bytes(report.bytesWritten)) written in \(Self.ms(report.seconds))",
            facts: [
                Fact(
                    .saved, edit: stamp.edit, document: name, at: stamp.savedAt, device: device.id, storage: content.kind,
                    style: style, sync: stamp.sync, seconds: report.seconds, bytes: report.bytesWritten)
            ])
        guard isInICloud(doc) else { return true }
        switch stamp.sync {
        case .system:
            watchUpload(doc, edit: stamp.edit)
        case .uploadNow:
            // Not awaited, so edits keep the same pace as when iCloud decides.
            Task { await uploadNow(doc, edits: [stamp.edit], failOnConflict: false) }
        case .paused:
            if await uploadNow(doc, edits: [stamp.edit], failOnConflict: true) == .conflict {
                guard attempt < 3 else {
                    record("conflict", name, "\(stamp.edit) gave up after \(attempt) tries")
                    return false
                }
                return await rebase(doc, action: action, edit: stamp.edit, sync: stamp.sync, attempt: attempt + 1)
            }
        }
        return true
    }

    /// With the system in charge of uploads, polls the upload flags after each save. An upload
    /// counts once the flags have shown it pending and then done; later edits are covered by the
    /// upload that finishes after them.
    func watchUpload(_ doc: URL, edit: EditID) {
        pendingUploads[doc, default: []].append(edit)
        uploadSaveTime[doc] = .now
        guard uploadWatch[doc] == nil else { return }
        uploadWatch[doc] = Task { await pollUpload(doc) }
    }

    private func pollUpload(_ doc: URL) async {
        let name = name(of: doc)
        let kind = StorageKind(url: doc)
        var sawPending = false
        var since = uploadSaveTime[doc] ?? .now
        while let edits = pendingUploads[doc], !edits.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            if let latest = uploadSaveTime[doc], latest != since {
                sawPending = false
                since = latest
            }
            let status = await Task.detached { UploadStatus.read(doc, kind: kind) }.value
            if !status.uploaded || status.uploading {
                sawPending = true
            } else if sawPending {
                let now = Date.now
                let edits = pendingUploads[doc] ?? []
                record(
                    "uploaded", name, "\(edits.map(\.description).joined(separator: ", ")) uploaded",
                    facts: edits.map { Fact(.uploaded, edit: $0, document: name, at: now, device: device.id) })
                pendingUploads[doc] = []
            } else if Date.now.timeIntervalSince(since) > 10 {
                record(
                    "upload", name,
                    "the flags never showed \(edits.map(\.description).joined(separator: ", ")) pending, so no upload time",
                    facts: edits.map { Fact(.problem, edit: $0, document: name, at: .now, device: device.id, note: "upload: flags never showed it") })
                pendingUploads[doc] = []
            }
        }
        uploadWatch[doc] = nil
    }
}

/// iCloud's upload flags, read fresh from disk for a document and every file inside it.
nonisolated struct UploadStatus: Sendable {
    var uploaded = true
    var uploading = false

    /// A zip or a package is one item; a plain folder is its files. Subfolders are skipped, since
    /// their flags never settle.
    static func read(_ doc: URL, kind: StorageKind?) -> UploadStatus {
        var targets = [doc]
        if kind == .folder,
            let files = FileManager.default.enumerator(
                at: doc, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        {
            targets = []
            for case let file as URL in files
            where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                targets.append(file)
            }
        }
        var status = UploadStatus()
        for var url in targets {
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey])
            else { continue }
            if values.ubiquitousItemIsUploaded == false { status.uploaded = false }
            if values.ubiquitousItemIsUploading == true { status.uploading = true }
        }
        return status
    }
}
