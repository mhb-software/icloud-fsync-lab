import Foundation
import LabKit

/// The log is one JSON line per entry in Application Support, outside the iCloud container.
/// Entries that carry a fact feed the results table; facts from the other device are kept too,
/// so results survive a relaunch.
extension Lab {
    static let supportFolder = URL.applicationSupportDirectory.appending(path: "FsyncLab", directoryHint: .isDirectory)
    static var logURL: URL { supportFolder.appending(path: "log.jsonl") }

    func loadLog() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.logURL) {
            let decoder = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? decoder.decode(LogEntry.self, from: Data(line)) else { continue }
                if let fact = entry.fact { remember(fact, fromPeer: entry.event == "peer") }
                if entry.event != "peer" { entries.append(entry) }
            }
            entries = Array(entries.suffix(3000))
        }
        if !fileManager.fileExists(atPath: Self.logURL.path) {
            fileManager.createFile(atPath: Self.logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: Self.logURL)
        _ = try? logHandle?.seekToEnd()
    }

    func record(_ event: String, _ document: String?, _ detail: String, facts: [Fact] = []) {
        let entry = LogEntry(event: event, document: document, detail: detail, fact: facts.first)
        entries.append(entry)
        if entries.count > 4000 { entries.removeFirst(1000) }
        write(entry)
        for fact in facts.dropFirst() {
            write(LogEntry(event: event, document: document, detail: "\(fact.kind.rawValue) \(fact.edit)", fact: fact))
        }
        for fact in facts { remember(fact, fromPeer: false) }
        link.send(facts)
    }

    func mergePeerFacts(_ incoming: [Fact]) {
        for fact in incoming where facts[fact.id] == nil {
            remember(fact, fromPeer: true)
            write(LogEntry(event: "peer", document: fact.document, detail: "\(fact.kind.rawValue) \(fact.edit)", fact: fact))
            expectArrival(of: fact)
        }
    }

    /// Starts an empty log. The old one stays beside it with the date in its name.
    func newLog() {
        try? logHandle?.close()
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        try? FileManager.default.moveItem(
            at: Self.logURL, to: Self.supportFolder.appending(path: "log \(stamp).jsonl"))
        entries = []
        facts = [:]
        peerFactIDs = []
        readEdits = []
        reportedMissing = []
        outcomes = []
        switchTest = nil
        loadLog()
        record("log", nil, "new log")
    }

    var ownFacts: [Fact] { facts.values.filter { !peerFactIDs.contains($0.id) } }
    var rows: [ResultRow] { Results.rows(facts.values, offsets: offsets) }
    var csv: String { Results.csv(rows, names: names.merging([device.id: device.name]) { $1 }) }

    private func remember(_ fact: Fact, fromPeer: Bool) {
        facts[fact.id] = fact
        if fromPeer { peerFactIDs.insert(fact.id) }
        if fact.device == device.id, fact.kind == .saved || fact.kind == .readable { readEdits.insert(fact.edit) }
    }

    private func write(_ entry: LogEntry) {
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        try? logHandle?.write(contentsOf: line)
    }
}
