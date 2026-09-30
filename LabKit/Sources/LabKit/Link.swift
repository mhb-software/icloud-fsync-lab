import Foundation

/// This install of the lab. The id names the device in edit ids, logs and the link.
public struct DeviceIdentity: Codable, Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String = String(UUID().uuidString.prefix(8)), name: String) {
        self.id = id
        self.name = name
    }
}

/// What two copies of the lab say to each other. Facts carry every measurement; the rest is
/// introductions and clock checks.
public enum LinkMessage: Codable, Sendable {
    case hello(DeviceIdentity)
    case ping(id: UUID, sentAt: Date)
    case pong(id: UUID, sentAt: Date, repliedAt: Date)
    case facts([Fact])
    /// Asks the other device to make one edit to a document at a moment in the sender's clock,
    /// so both devices edit at once: the conflict test.
    case editAt(document: String, at: Date, sync: SyncMode)
    /// A line for the other device's log, such as a conflict test's outcome.
    case note(String)
    /// The test running on the sender, or none, so every linked device shows it.
    case test(TestStatus?)
    /// Asks the device running a test to stop it.
    case stopTest
    /// Asks for the device's whole log, to save beside this one.
    case logRequest(id: UUID)
    case log(id: UUID, device: DeviceIdentity, data: Data)
}

/// A test in progress. The device that started it sends this whenever it changes.
public struct TestStatus: Codable, Sendable, Equatable {
    public enum Test: String, Codable, Sendable { case speed, conflict, iCloud }

    public var id = UUID()
    public var test: Test
    public var startedBy: DeviceIdentity
    public var writing: Writing?
    public var sync: SyncMode
    /// The format being tested now.
    public var kind: StorageKind?
    /// What is happening now, in words.
    public var step: String
    /// The mixes this run made, so every device can show the run's numbers.
    public var documents: [String] = []
    public var finished = false

    public init(test: Test, startedBy: DeviceIdentity, sync: SyncMode, step: String) {
        self.test = test
        self.startedBy = startedBy
        self.sync = sync
        self.step = step
    }
}

/// Estimates how far a peer's clock is ahead of ours from ping round trips, trusting the
/// quickest round trip most, as NTP does.
public struct ClockOffset: Sendable {
    public struct Sample: Sendable {
        public var sent: Date
        public var peer: Date
        public var received: Date

        public init(sent: Date, peer: Date, received: Date) {
            self.sent = sent
            self.peer = peer
            self.received = received
        }
    }

    public private(set) var samples: [Sample] = []

    public init() {}

    public mutating func add(_ sample: Sample) {
        samples.append(sample)
        if samples.count > 16 { samples.removeFirst() }
    }

    /// Seconds the peer's clock is ahead of ours, and the round trip that estimate came from.
    public var estimate: (offset: Double, roundTrip: Double)? {
        samples.map { sample in
            let roundTrip = sample.received.timeIntervalSince(sample.sent)
            return (sample.peer.timeIntervalSince(sample.sent) - roundTrip / 2, roundTrip)
        }
        .min { $0.1 < $1.1 }
    }
}
