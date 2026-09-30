import FileProvider
import Foundation
import LabKit

/// The sync controls added in iOS and macOS 26: pause, resume, upload now, fetch latest now.
extension Lab {
    enum UploadOutcome { case uploaded, conflict, failed }

    /// Asks iCloud to upload now. With `failOnConflict`, which needs sync paused, it refuses
    /// when the server already has a newer version: the stale device, caught at the source.
    @discardableResult
    func uploadNow(_ doc: URL, edits: [EditID], failOnConflict: Bool) async -> UploadOutcome {
        let name = name(of: doc)
        let list = edits.isEmpty ? "the current version" : edits.map(\.description).joined(separator: ", ")
        let start = ContinuousClock.now
        let policy: NSFileManagerUploadLocalVersionConflictPolicy =
            failOnConflict ? .conflictPolicyFailOnConflict : .conflictPolicyDefault
        do {
            let version = try await FileManager.default.uploadLocalVersionOfUbiquitousItem(
                at: doc, withConflictResolutionPolicy: policy)
            let now = Date.now
            record(
                "uploaded", name, "upload now for \(list) took \(Self.ms(since: start)), version from \(version.localizedNameOfSavingComputer ?? "unknown")",
                facts: edits.map { Fact(.uploaded, edit: $0, document: name, at: now, device: device.id) })
            return .uploaded
        } catch {
            if Self.isServerNewer(error) {
                record(
                    "conflict", name, "upload now for \(list) refused after \(Self.ms(since: start)): the server has a newer version",
                    facts: edits.map { Fact(.problem, edit: $0, document: name, at: .now, device: device.id, note: "server was newer at upload") })
                return .conflict
            }
            record("error", name, "upload now for \(list) failed after \(Self.ms(since: start)): \(Self.describe(error))")
            return .failed
        }
    }

    func pause(_ doc: URL) async {
        let start = ContinuousClock.now
        do {
            try await FileManager.default.pauseSyncForUbiquitousItem(at: doc)
            record("paused", name(of: doc), "sync paused in \(Self.ms(since: start))")
        } catch {
            record("error", name(of: doc), "pause failed: \(Self.describe(error))")
        }
        await refreshControls(doc)
    }

    func resume(_ doc: URL, _ behavior: NSFileManagerResumeSyncBehavior) async {
        let start = ContinuousClock.now
        let label =
            switch behavior {
            case .preserveLocalChanges: "keeping local changes"
            case .afterUploadWithFailOnConflict: "after an upload that fails on conflict"
            case .dropLocalChanges: "dropping local changes"
            @unknown default: "\(behavior.rawValue)"
            }
        do {
            try await FileManager.default.resumeSyncForUbiquitousItem(at: doc, with: behavior)
            record("resumed", name(of: doc), "sync resumed \(label) in \(Self.ms(since: start))")
        } catch {
            record(Self.isServerNewer(error) ? "conflict" : "error", name(of: doc), "resume \(label) failed: \(Self.describe(error))")
        }
        await refreshControls(doc)
    }

    /// Asks the server for its newest version now. Unpaused, this replaces the local copy;
    /// paused, the version waits at a side location.
    func fetchLatest(_ doc: URL) async {
        let start = ContinuousClock.now
        do {
            let version = try await FileManager.default.fetchLatestRemoteVersionOfItem(at: doc)
            record(
                "fetched", name(of: doc),
                "fetch latest took \(Self.ms(since: start)): version from \(version.localizedNameOfSavingComputer ?? "unknown")")
            staleContents.insert(doc)
            downloadRequested.remove(doc)
            if pendingListed[doc] != nil { await readArrival(doc) }
        } catch {
            downloadRequested.remove(doc)
            record("error", name(of: doc), "fetch latest failed after \(Self.ms(since: start)): \(Self.describe(error))")
        }
    }

    /// The paused mode's answer to a refused upload: take the server's version, redo the same
    /// edit on top, and upload again, so neither edit is lost.
    func rebase(_ doc: URL, action: Action, edit: EditID, sync: SyncMode, attempt: Int) async -> Bool {
        let name = name(of: doc)
        do {
            let version = try await FileManager.default.fetchLatestRemoteVersionOfItem(at: doc)
            let savedBy = version.localizedNameOfSavingComputer ?? "unknown"
            var coordinationError: NSError?
            var replaceError: (any Error)?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: doc, options: .forReplacing, error: &coordinationError) {
                url in
                do { _ = try version.replaceItem(at: url, options: []) } catch { replaceError = error }
            }
            if let error = coordinationError ?? replaceError.map({ $0 as NSError }) { throw error }
            staleContents.insert(doc)
            record("rebase", name, "took the server's version from \(savedBy) and redoing \(edit) \(action.rawValue) on top")
            return await act(action, on: doc, edit: edit, sync: sync, attempt: attempt)
        } catch {
            record("error", name, "rebase failed: \(Self.describe(error))")
            return false
        }
    }

    /// Which controls iCloud Drive offers for this item, and whether it is paused.
    func refreshControls(_ doc: URL) async {
        var url = doc
        url.removeAllCachedResourceValues()
        guard isInICloud(doc),
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemSupportedSyncControlsKey, .ubiquitousItemIsSyncPausedKey])
        else {
            controls[doc] = isInICloud(doc) ? "unknown" : "not in iCloud"
            return
        }
        let supported = values.ubiquitousItemSupportedSyncControls ?? []
        controls[doc] = [
            "pause \(supported.contains(.pauseSync) ? "supported" : "not supported")",
            "fail on conflict \(supported.contains(.failUploadOnConflict) ? "supported" : "not supported")",
            values.ubiquitousItemIsSyncPaused == true ? "paused now" : "syncing",
        ].joined(separator: ", ")
    }

    static func isServerNewer(_ error: any Error) -> Bool {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return [error, underlying].contains {
            $0?.domain == NSFileProviderErrorDomain && $0?.code == NSFileProviderError.Code.localVersionConflictingWithServer.rawValue
        }
    }
}
