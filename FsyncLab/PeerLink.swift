import Foundation
import LabKit
import Network

/// Finds the other copy of the lab on the local network with Bonjour and swaps facts with it,
/// so both devices hold complete rows, and pings it to measure the clock offset. Both copies
/// advertise and browse; the one with the smaller device id dials, so a pair has one connection.
/// Peer to peer Wi-Fi stays off, Network framework's default, so the link does not disturb the
/// network timings being measured.
@Observable
final class PeerLink {
    static let serviceType = "_fsynclab._tcp"
    typealias Channel = NetworkConnection<Coder<LinkMessage, LinkMessage, NetworkJSONCoder>>

    struct Peer: Identifiable {
        var id: String
        var name: String
        var connected: Bool
        var offset: Double?
        var roundTrip: Double?
    }

    @ObservationIgnored weak var lab: Lab?
    private(set) var peers: [String: Peer] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var channels: [String: Channel] = [:]
    @ObservationIgnored private var dialing: Set<String> = []
    @ObservationIgnored private var clocks: [String: ClockOffset] = [:]
    @ObservationIgnored private var visible: Set<String> = []
    @ObservationIgnored private var receivedLogs: [UUID: [String: (DeviceIdentity, Data)]] = [:]

    var connectedPeers: [Peer] { peers.values.filter(\.connected).sorted { $0.name < $1.name } }

    /// Every linked device's whole log, as far as they answer within the timeout.
    func requestLogs(timeout: Double = 20) async -> [(DeviceIdentity, Data)] {
        let expected = channels.count
        guard expected > 0 else { return [] }
        let id = UUID()
        receivedLogs[id] = [:]
        send(.logRequest(id: id))
        let deadline = Date.now.addingTimeInterval(timeout)
        while (receivedLogs[id]?.count ?? 0) < expected, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return (receivedLogs.removeValue(forKey: id) ?? [:]).values.sorted { $0.0.name < $1.0.name }
    }

    /// Sends a message to every connected device, or only to the ones named.
    func send(_ message: LinkMessage, to ids: [String]? = nil) {
        for (id, channel) in channels where ids?.contains(id) ?? true {
            Task { try? await channel.send(message) }
        }
    }

    func start() {
        guard tasks.isEmpty, let lab else { return }
        let me = lab.device
        tasks = [
            Task { await listen(as: me) },
            Task { await browse(as: me) },
            Task { await keepPinging() },
        ]
    }

    /// Sends facts to every connected device. The other side ignores ones it already has.
    func send(_ facts: [Fact]) {
        guard !facts.isEmpty else { return }
        for channel in channels.values {
            Task { try? await send(facts, on: channel) }
        }
    }

    private func listen(as me: DeviceIdentity) async {
        do {
            let service = String("\(me.id) \(me.name)".prefix(60))
            let listener = try NetworkListener(for: BonjourListenerProvider(name: service, type: Self.serviceType)) {
                Coder(LinkMessage.self, using: .json) { TCP() }
            }
            try await listener.run { connection in
                await self.serve(connection)
            }
        } catch {
            lab?.record("link", nil, "stopped listening: \(Lab.describe(error))")
        }
    }

    private func browse(as me: DeviceIdentity) async {
        do {
            try await NetworkBrowser(for: .bonjour(Self.serviceType)).run { endpoints in
                self.visible = Set(endpoints.map { String($0.name.prefix { $0 != " " }) })
                for endpoint in endpoints {
                    let peerID = String(endpoint.name.prefix { $0 != " " })
                    guard me.id < peerID, !self.dialing.contains(peerID) else { continue }
                    self.dialing.insert(peerID)
                    Task { await self.dial(endpoint, peerID: peerID) }
                }
            }
        } catch {
            lab?.record("link", nil, "stopped browsing: \(Lab.describe(error))")
        }
    }

    /// Keeps a connection up while the other device is listed, backing off after failures.
    private func dial(_ endpoint: Bonjour.Endpoint, peerID: String) async {
        defer { dialing.remove(peerID) }
        var wait = 2.0
        var reported = false
        while visible.contains(peerID), !Task.isCancelled {
            let connection = NetworkConnection(to: endpoint) { Coder(LinkMessage.self, using: .json) { TCP() } }
            if await serve(connection) {
                wait = 2
                reported = false
            } else if !reported {
                reported = true
                lab?.record("link", nil, "cannot reach \(endpoint.name) yet; retrying")
            }
            try? await Task.sleep(for: .seconds(wait))
            wait = min(wait * 2, 60)
        }
    }

    /// Runs one connection until it ends: introduce ourselves, send every fact we have, then
    /// answer pings and take in facts. Returns whether the other device answered.
    @discardableResult
    private func serve(_ connection: Channel) async -> Bool {
        guard let lab else { return false }
        var peerID: String?
        do {
            try await connection.send(LinkMessage.hello(lab.device))
            try await send(lab.ownFacts, on: connection)
            for try await message in connection.messages {
                switch message.content {
                case .hello(let peer):
                    peerID = peer.id
                    channels[peer.id] = connection
                    lab.names[peer.id] = peer.name
                    peers[peer.id] = Peer(id: peer.id, name: peer.name, connected: true)
                    lab.record("link", nil, "connected to \(peer.name)")
                    Task { await ping(peer.id) }
                    if let test = lab.activeTest, test.startedBy.id == lab.device.id {
                        try await connection.send(LinkMessage.test(test))
                    }
                case .ping(let id, let sentAt):
                    try await connection.send(LinkMessage.pong(id: id, sentAt: sentAt, repliedAt: .now))
                case .pong(_, let sentAt, let repliedAt):
                    guard let peerID else { break }
                    clocks[peerID, default: ClockOffset()].add(.init(sent: sentAt, peer: repliedAt, received: .now))
                    if let estimate = clocks[peerID]?.estimate {
                        // Logged when it first settles or moves, so saved logs can be corrected.
                        if lab.offsets[peerID].map({ abs($0 - estimate.offset) > 0.05 }) ?? true {
                            lab.record(
                                "clock", nil,
                                "\(lab.names[peerID] ?? peerID)'s clock is \(Int((estimate.offset * 1000).rounded())) ms ahead of this one, round trip \(Int((estimate.roundTrip * 1000).rounded())) ms")
                        }
                        lab.offsets[peerID] = estimate.offset
                        peers[peerID]?.offset = estimate.offset
                        peers[peerID]?.roundTrip = estimate.roundTrip
                    }
                case .facts(let facts):
                    lab.mergePeerFacts(facts)
                case .editAt(let document, let moment, let sync):
                    lab.peerAskedForEdit(document: document, at: moment, sync: sync, from: peerID)
                case .note(let text):
                    lab.record("note", nil, "\(peerID.flatMap { lab.names[$0] } ?? "The other device"): \(text)")
                case .test(let status):
                    lab.peerTest(status, from: peerID)
                case .stopTest:
                    if lab.activeTest?.startedBy.id == lab.device.id { lab.stopTest() }
                case .logRequest(let id):
                    try? lab.logHandle?.synchronize()
                    let log = (try? Data(contentsOf: Lab.logURL)) ?? Data()
                    try await connection.send(LinkMessage.log(id: id, device: lab.device, data: log))
                case .log(let id, let peer, let log):
                    receivedLogs[id]?[peer.id] = (peer, log)
                }
            }
        } catch {
            if peerID != nil { lab.record("link", nil, "connection ended: \(Lab.describe(error))") }
        }
        if let peerID, channels[peerID] === connection {
            channels[peerID] = nil
            peers[peerID]?.connected = false
            lab.record("link", nil, "disconnected from \(lab.names[peerID] ?? peerID)")
            lab.peerLost(peerID)
        }
        return peerID != nil
    }

    private func send(_ facts: [Fact], on channel: Channel) async throws {
        for start in stride(from: 0, to: facts.count, by: 200) {
            try await channel.send(LinkMessage.facts(Array(facts[start..<min(start + 200, facts.count)])))
        }
    }

    /// A burst of pings now and then; the quickest round trip gives the offset.
    private func keepPinging() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            for peerID in channels.keys { await ping(peerID) }
        }
    }

    private func ping(_ peerID: String) async {
        for _ in 0..<5 {
            guard let channel = channels[peerID] else { return }
            try? await channel.send(LinkMessage.ping(id: UUID(), sentAt: .now))
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
