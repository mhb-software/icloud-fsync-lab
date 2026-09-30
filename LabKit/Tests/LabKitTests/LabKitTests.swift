import Foundation
import Testing
import ZIPFoundation

@testable import LabKit

private let device = "AAAA0000"

private func scratchFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LabKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func newDocument(_ kind: StorageKind, style: WriteStyle, photos: Int = 3) -> DocumentContent {
    .new(
        title: "Doc", kind: kind, photos: photos, edit: EditID(device: device, number: 1), deviceName: "Mac",
        style: style, sync: .system)
}

private func fileNumber(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int ?? -1
}

@Test func zipMatchesMixLayout() throws {
    let url = try scratchFolder().appendingPathComponent("Doc.labzip")
    _ = try DocumentWriter.write(newDocument(.zip, style: .deleteThenCreate), to: url, style: .deleteThenCreate)
    let entries = Array(try Archive(url: url, accessMode: .read))
    #expect(entries.prefix(3).map(\.path) == ["Info.json", "mix.json", "preview.jpg"])
    let resources = entries.dropFirst(3).map(\.path)
    #expect(resources == resources.sorted())
    #expect(resources.count == 3 * 2 + 1)
    for entry in entries {
        let stored = entry.compressedSize == entry.uncompressedSize
        #expect(stored == !entry.path.hasSuffix(".json"), "\(entry.path)")
    }
}

private let everyKindAndStyle = StorageKind.allCases.flatMap { kind in kind.writeStyles.map { (kind, $0) } }

@Test(arguments: everyKindAndStyle)
func everyKindAndStyleRoundTrips(kind: StorageKind, style: WriteStyle) throws {
    let url = try scratchFolder().appendingPathComponent("Doc.\(kind.fileExtension)")
    var content = newDocument(kind, style: style)
    _ = try DocumentWriter.write(content, to: url, style: style)
    let actions: [Action] = [.move, .addPhoto, .removePhoto, .move, .close]
    for (offset, action) in actions.enumerated() {
        let edit = EditID(device: device, number: offset + 2)
        content.apply(action, edit: edit, deviceName: "Mac", style: style, sync: .system)
        let report = try DocumentWriter.write(content, to: url, style: style)
        #expect(report.bytesWritten > 0)
        let read = DocumentReader.read(url, kind: kind)
        #expect(read.problems == [])
        #expect(read.stamp?.edit == edit)
        #expect(read.content?.photoCount == content.photoCount)
    }
    #expect(DocumentReader.read(url, kind: kind).stamp?.history.map(\.action) == [.create] + actions)
}

@Test func changedFilesWriteOnlyWhatChanged() throws {
    let folder = try scratchFolder()
    for style in [WriteStyle.changedInPlace, .changedSwapped] {
        let url = folder.appendingPathComponent("\(style).labpkg")
        var content = newDocument(.package, style: style, photos: 8)
        let first = try DocumentWriter.write(content, to: url, style: style)
        content.apply(.move, edit: EditID(device: device, number: 2), deviceName: "Mac", style: style, sync: .system)
        let move = try DocumentWriter.write(content, to: url, style: style)
        #expect(first.bytesWritten > 2_000_000)
        #expect(move.bytesWritten < 400_000, "a move writes mix.json and the preview only")
        content.apply(.removePhoto, edit: EditID(device: device, number: 3), deviceName: "Mac", style: style, sync: .system)
        _ = try DocumentWriter.write(content, to: url, style: style)
        let resources = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("resources").path)
        #expect(resources.count == 7 * 2 + 1, "the removed photo's files are gone")
    }
}

@Test func inPlaceKeepsTheSameFileAndSwapDoesNot() throws {
    let folder = try scratchFolder()
    for (style, keepsFile) in [(WriteStyle.overwriteInPlace, true), (.swapTemp, false), (.deleteThenCreate, false)] {
        let url = folder.appendingPathComponent("\(style).labzip")
        var content = newDocument(.zip, style: style)
        _ = try DocumentWriter.write(content, to: url, style: style)
        let before = try fileNumber(url)
        content.apply(.move, edit: EditID(device: device, number: 2), deviceName: "Mac", style: style, sync: .system)
        _ = try DocumentWriter.write(content, to: url, style: style)
        #expect((try fileNumber(url) == before) == keepsFile, "\(style)")
    }
}

@Test func checkCatchesAFolderFromTwoSaves() throws {
    let url = try scratchFolder().appendingPathComponent("Doc.labfolder")
    _ = try DocumentWriter.write(newDocument(.folder, style: .deleteThenCreate), to: url, style: .deleteThenCreate)
    #expect(DocumentReader.read(url, kind: .folder).isConsistent)
    try Data(repeating: 7, count: 1000).write(to: url.appendingPathComponent("preview.jpg"))
    try Data("{}".utf8).write(to: url.appendingPathComponent("mix 2.json"))
    let read = DocumentReader.read(url, kind: .folder)
    #expect(read.problems.contains("preview.jpg is from another save"))
    #expect(read.problems.contains("unexpected mix 2.json"))
}

@Test func checkCatchesATruncatedZip() throws {
    let url = try scratchFolder().appendingPathComponent("Doc.labzip")
    _ = try DocumentWriter.write(newDocument(.zip, style: .swapTemp), to: url, style: .swapTemp)
    let data = try Data(contentsOf: url)
    try data.prefix(data.count / 2).write(to: url)
    #expect(DocumentReader.read(url, kind: .zip).content == nil)
}

@Test func resultsCorrectForClockOffset() throws {
    let edit = EditID(device: "SEND0000", number: 7)
    let saved = Date(timeIntervalSince1970: 1_000_000)
    let facts = [
        Fact(
            .saved, edit: edit, document: "D", at: saved, device: "SEND0000", storage: .zip, style: .swapTemp,
            sync: .system, seconds: 0.12, bytes: 5_000_000),
        Fact(.uploaded, edit: edit, document: "D", at: saved + 4, device: "SEND0000"),
        Fact(.listed, edit: edit, document: "D", at: saved + 12, device: "RECV0000"),
        Fact(.readable, edit: edit, document: "D", at: saved + 15, device: "RECV0000"),
        Fact(.problem, edit: edit, document: "D", at: saved + 15, device: "RECV0000", note: "conflict"),
    ]
    // The receiver's clock runs 2 seconds ahead of this device's.
    let row = try #require(Results.rows(facts, offsets: ["RECV0000": 2]).first)
    #expect(row.uploaded == 4)
    let arrival = try #require(row.arrivals.first)
    #expect(arrival.device == "RECV0000")
    #expect(arrival.listed == 10)
    #expect(arrival.readable == 13)
    #expect(row.writeSeconds == 0.12)
    #expect(row.notes == ["conflict"])
    let csv = Results.csv([row], names: ["SEND0000": "Mac"])
    #expect(csv.split(separator: "\n").count == 2)
    #expect(csv.contains("SEND0000#7"))
}

@Test func clockOffsetTrustsTheQuickestRoundTrip() throws {
    var clock = ClockOffset()
    let start = Date(timeIntervalSince1970: 0)
    // The peer runs 5 seconds ahead. A slow round trip with lopsided delays would mislead.
    clock.add(.init(sent: start, peer: start + 5.9, received: start + 1))
    clock.add(.init(sent: start + 10, peer: start + 15.01, received: start + 10.02))
    let estimate = try #require(clock.estimate)
    #expect(abs(estimate.offset - 5) < 0.001)
    #expect(abs(estimate.roundTrip - 0.02) < 0.001)
}

@Test func linkMessagesRoundTrip() throws {
    let fact = Fact(.readable, edit: EditID(device: device, number: 3), document: "D", at: .now, device: "B")
    let data = try JSONEncoder().encode(LinkMessage.facts([fact]))
    guard case .facts(let facts) = try JSONDecoder().decode(LinkMessage.self, from: data) else {
        Issue.record("wrong message")
        return
    }
    #expect(facts == [fact])
}
