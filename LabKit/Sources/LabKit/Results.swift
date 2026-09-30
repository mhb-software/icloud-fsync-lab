import Foundation

/// One measured moment about one edit. Devices share their facts over the link, and the
/// results table is folded from all of them.
public struct Fact: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case saved, uploaded, listed, readable, problem
    }

    public var id: UUID
    public var kind: Kind
    public var edit: EditID
    public var document: String
    public var at: Date
    /// The device whose clock `at` is in: the sender for saved and uploaded, the receiver for
    /// listed and readable, the observer for problems.
    public var device: String
    public var storage: StorageKind?
    public var style: WriteStyle?
    public var sync: SyncMode?
    /// Write time for a save.
    public var seconds: Double?
    public var bytes: Int?
    public var note: String?

    public init(
        _ kind: Kind, edit: EditID, document: String, at: Date, device: String, storage: StorageKind? = nil,
        style: WriteStyle? = nil, sync: SyncMode? = nil, seconds: Double? = nil, bytes: Int? = nil,
        note: String? = nil
    ) {
        id = UUID()
        self.kind = kind
        self.edit = edit
        self.document = document
        self.at = at
        self.device = device
        self.storage = storage
        self.style = style
        self.sync = sync
        self.seconds = seconds
        self.bytes = bytes
        self.note = note
    }
}

/// When one receiving device noticed an edit and when it could read it whole, in seconds after
/// the save.
public struct Arrival: Sendable, Hashable {
    public var device: String
    public var listed: Double?
    public var readable: Double?
}

/// One row of the results table. Times after `savedAt` are in seconds, corrected for clock offset.
public struct ResultRow: Identifiable, Sendable {
    public var id: EditID { edit }
    public var edit: EditID
    public var document: String
    public var storage: StorageKind?
    public var style: WriteStyle?
    public var sync: SyncMode?
    /// In this device's clock.
    public var savedAt: Date?
    public var writeSeconds: Double?
    public var bytes: Int?
    public var uploaded: Double?
    /// One per device that received the edit, in device id order.
    public var arrivals: [Arrival]
    public var notes: [String]
}

public enum Results {
    /// Folds facts into one row per edit. `offsets` says how many seconds each device's clock is
    /// ahead of this device's; this device and unknown devices count as zero.
    public static func rows(_ facts: some Sequence<Fact>, offsets: [String: Double]) -> [ResultRow] {
        func local(_ fact: Fact) -> Date { fact.at.addingTimeInterval(-(offsets[fact.device] ?? 0)) }
        func earliest(_ facts: [Fact]) -> Fact? { facts.min { $0.at < $1.at } }

        return Dictionary(grouping: facts, by: \.edit).map { edit, facts in
            let saves = facts.filter { $0.kind == .saved }
            let saved = earliest(saves.filter { $0.device == edit.device }) ?? earliest(saves)
            let origin = saved.map(local)
            func after(_ fact: Fact?) -> Double? {
                guard let fact, let origin else { return nil }
                return local(fact).timeIntervalSince(origin)
            }
            let received = facts.filter { ($0.kind == .listed || $0.kind == .readable) && $0.device != edit.device }
            let arrivals = Dictionary(grouping: received, by: \.device).map { device, facts in
                Arrival(
                    device: device,
                    listed: after(earliest(facts.filter { $0.kind == .listed })),
                    readable: after(earliest(facts.filter { $0.kind == .readable })))
            }
            let detailed = saves.first { $0.seconds != nil }
            var notes: [String] = []
            for note in facts.filter({ $0.kind == .problem }).sorted(by: { $0.at < $1.at }).compactMap(\.note)
            where !notes.contains(note) {
                notes.append(note)
            }
            return ResultRow(
                edit: edit,
                document: saved?.document ?? facts[0].document,
                storage: saved?.storage ?? facts.lazy.compactMap(\.storage).first,
                style: saved?.style ?? facts.lazy.compactMap(\.style).first,
                sync: saved?.sync ?? facts.lazy.compactMap(\.sync).first,
                savedAt: origin,
                writeSeconds: detailed?.seconds,
                bytes: detailed?.bytes,
                uploaded: after(earliest(facts.filter { $0.kind == .uploaded })),
                arrivals: arrivals.sorted { $0.device < $1.device },
                notes: notes)
        }
        .sorted { ($0.savedAt ?? .distantPast, $0.edit) < ($1.savedAt ?? .distantPast, $1.edit) }
    }

    /// One line per edit per receiving device.
    public static func csv(_ rows: [ResultRow], names: [String: String]) -> String {
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = [
            "edit,document,kind,style,sync,sender,saved,write_ms,bytes_written,uploaded_s,receiver,listed_s,readable_s,notes"
        ]
        for row in rows {
            for arrival in row.arrivals.isEmpty ? [nil] : row.arrivals.map(Optional.some) {
            let fields: [String] = [
                row.edit.description,
                quoted(row.document),
                row.storage?.rawValue ?? "",
                row.style?.rawValue ?? "",
                row.sync?.rawValue ?? "",
                quoted(names[row.edit.device] ?? row.edit.device),
                row.savedAt.map { $0.formatted(time) } ?? "",
                row.writeSeconds.map { String(format: "%.1f", $0 * 1000) } ?? "",
                row.bytes.map(String.init) ?? "",
                seconds(row.uploaded),
                quoted(arrival.map { names[$0.device] ?? $0.device } ?? ""),
                seconds(arrival?.listed),
                seconds(arrival?.readable),
                quoted(row.notes.joined(separator: "; ")),
            ]
            lines.append(fields.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One line of a device's log. Entries that carry a fact feed the results table.
public struct LogEntry: Codable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    public var event: String
    public var document: String?
    public var detail: String
    public var fact: Fact?

    public init(at: Date = .now, event: String, document: String? = nil, detail: String, fact: Fact? = nil) {
        id = UUID()
        self.at = at
        self.event = event
        self.document = document
        self.detail = detail
        self.fact = fact
    }
}
