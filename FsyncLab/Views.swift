import CoreTransferable
import LabKit
import SwiftUI
import UniformTypeIdentifiers

/// The main screen: pick the upload option, run one of three tests, compare the formats.
struct MainView: View {
    @Environment(Lab.self) private var lab

    var body: some View {
        @Bindable var lab = lab
        let linked = !lab.link.connectedPeers.isEmpty
        let iCloud = lab.iCloudRoot != nil
        Form {
            Section("Writing") {
                Picker("Writing", selection: $lab.settings.writing) {
                    ForEach(Writing.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(lab.settings.writing.explanation).font(.footnote).foregroundStyle(.secondary)
            }

            Section("Uploading") {
                Picker("Uploading", selection: $lab.settings.sync) {
                    ForEach(SyncMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(lab.settings.sync.explanation).font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                testRow(.speed, "How soon an edit reaches your other devices.", enabled: iCloud) {
                    lab.runEditingTest()
                }
                testRow(.conflict, "Every linked device edits the same mix at the same moment.", enabled: iCloud && linked) {
                    lab.runConflictTest()
                }
                testRow(.iCloud, "What happens to mixes when iCloud is switched off for this app, and back on.", enabled: iCloud) {
                    lab.startSwitchTest()
                }
            } header: {
                Text("Tests")
            } footer: {
                Text(
                    "Each test runs on a Zip, a Package and a Folder."
                        + (linked ? "" : " Open fsync Lab on your other devices, on the same Wi-Fi, to link them."))
            }

            Section {
                ComparisonGrid(rows: lab.comparison())
                NavigationLink("Every edit") { ResultsView() }
            } header: {
                Text("Compared")
            } footer: {
                Text(
                    "Tests run from this device, writing \(lab.settings.writing.title.lowercased()), uploading \(lab.settings.sync.title.lowercased()). Readable: that device had the whole edit and every file checked out. Half updated: edits it read while only some files had arrived. Times are seconds after the save; with iCloud deciding, upload done is seconds after a run's last save, and not shown means iCloud never flagged the upload."
                )
            }

            Section {
                NavigationLink("Log") { LogView() }
                NavigationLink("Documents") { DocumentsView() }
                NavigationLink("Settings") { SettingsView() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("fsync Lab")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { StatusIcons(lab: lab) }
    }

    private func testRow(_ test: TestStatus.Test, _ detail: String, enabled: Bool, run: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(test.title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run", action: run)
                .buttonStyle(.borderedProminent)
                .disabled(!enabled || lab.isBusy)
        }
    }
}

/// Beside the title: linked devices, and a cloud that is lit when iCloud is on.
struct StatusIcons: ToolbarContent {
    let lab: Lab

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let peers = lab.link.connectedPeers
            Menu {
                if peers.isEmpty { Text("No linked devices") }
                ForEach(peers) { peer in
                    Text(peer.offset.map { "\(peer.name), clocks \(Int(abs($0) * 1000)) ms apart" } ?? peer.name)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("\(peers.count)")
                }
                .foregroundStyle(peers.isEmpty ? .secondary : .primary)
            }
            .accessibilityLabel("\(peers.count) linked devices")
            Image(systemName: lab.iCloudRoot != nil ? "icloud.fill" : "icloud.slash")
                .foregroundStyle(lab.iCloudRoot != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(lab.iCloudState)
                .help(lab.iCloudState)
        }
    }
}

/// While a test runs anywhere, every linked device shows this instead of the main screen.
struct RunningView: View {
    @Environment(Lab.self) private var lab
    let test: TestStatus

    private var here: Bool { test.startedBy.id == lab.device.id }

    var body: some View {
        Form {
            Section {
                if test.test != .iCloud {
                    HStack(spacing: 16) {
                        ForEach(StorageKind.allCases) { kind in
                            Label(kind.title, systemImage: symbol(kind))
                                .foregroundStyle(kind == test.kind && !test.finished ? .primary : .secondary)
                        }
                    }
                    .font(.subheadline)
                }
                HStack(spacing: 10) {
                    if !test.finished { ProgressView() }
                    Text(test.step)
                }
                if test.test == .iCloud, here { SwitchTestControls() }
            } header: {
                Text([test.writing?.title, test.sync.title].compactMap { $0 }.joined(separator: ", "))
            } footer: {
                Text(footer)
            }
            Section("This run") {
                ComparisonGrid(rows: lab.comparison(documents: Set(test.documents)))
            }
            Section("Latest") {
                ForEach(lab.entries.suffix(5).reversed()) { entry in
                    Text(entry.detail).font(.footnote)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(test.test.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if test.finished {
                    Button("Done") { lab.dismissTest() }
                } else {
                    Button("Stop", role: .destructive) { lab.stopTest() }
                }
            }
        }
    }

    private var footer: String {
        if here { return "Running on this device. Linked devices follow along." }
        return switch test.test {
        case .speed: "Started on \(test.startedBy.name). This device times each edit as it arrives."
        case .conflict: "Started on \(test.startedBy.name). This device edits at the same moment."
        case .iCloud: "Running on \(test.startedBy.name)."
        }
    }

    /// Done, now, or still to come. The order changes from run to run, so a format is done when
    /// the test has made its mix (named after the format) and moved on.
    private func symbol(_ kind: StorageKind) -> String {
        if test.finished && test.step == "Finished" { return "checkmark.circle.fill" }
        if kind == test.kind { return test.finished ? "xmark.circle" : "circle.inset.filled" }
        return test.documents.contains { $0.hasPrefix("\(kind.rawValue) ") } ? "checkmark.circle.fill" : "circle"
    }
}

/// The iCloud test's report so far, and its one or two buttons, on the device running it.
struct SwitchTestControls: View {
    @Environment(Lab.self) private var lab

    var body: some View {
        if let test = lab.switchTest {
            ForEach(Array(test.report.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout)
            }
            if test.step == .waitingForOn, lab.iCloudRoot == nil, test.madeWhileOff.isEmpty {
                Button("Make a mix of each format while iCloud is off") { Task { await lab.makeMixesWhileOff() } }
            }
            if test.step == .done, lab.iCloudRoot != nil, lab.documents.contains(where: { !$0.inICloud }) {
                Button("Move the mixes on this device into iCloud") { Task { await lab.moveAllIntoICloud() } }
            }
        }
    }
}

/// Zip, Package and Folder side by side.
struct ComparisonGrid: View {
    let rows: [Lab.GridRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("")
                ForEach(StorageKind.allCases) { Text($0.title).bold() }
            }
            Divider()
            ForEach(rows) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary).lineLimit(2)
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell).foregroundStyle(cell == "not run" ? .tertiary : .primary)
                    }
                }
            }
        }
        .font(.footnote)
    }
}

struct SettingsView: View {
    @Environment(Lab.self) private var lab
    @State private var choosingFolder = false

    var body: some View {
        @Bindable var lab = lab
        Form {
            Section("This device") {
                TextField("Name", text: $lab.device.name)
            }
            Section("Editing test") {
                Stepper("\(lab.settings.actions) edits", value: $lab.settings.actions, in: 5...500, step: 5)
                Stepper(
                    "At least \(lab.settings.shortestPause, format: .number) s between edits",
                    value: $lab.settings.shortestPause, in: 0...lab.settings.longestPause, step: 0.5)
                Stepper(
                    "At most \(lab.settings.longestPause, format: .number) s between edits",
                    value: $lab.settings.longestPause, in: lab.settings.shortestPause...60, step: 0.5)
                Stepper("New mixes start with \(lab.settings.photos) photos", value: $lab.settings.photos, in: 1...40)
            }
            Section {
                Picker("Get the other device's edits by", selection: $lab.settings.fetch) {
                    ForEach(FetchMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Receiving")
            } footer: {
                Text("Start download is the usual way. Fetch latest now is new in iOS 26.")
            }
            Section {
                LabeledContent("Save logs to", value: lab.exportFolderName ?? "not chosen yet")
                Button("Choose a folder") { choosingFolder = true }
                Button("Start a new log") { lab.newLog() }
            } header: {
                Text("Logs")
            } footer: {
                Text("Save logs, on the Log screen, puts this device's log, the results, and every linked device's log in that folder. Starting a new log keeps the old one.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { lab.setExportFolder(folder) }
        }
    }
}

/// Every document, for trying things by hand.
struct DocumentsView: View {
    @Environment(Lab.self) private var lab

    var body: some View {
        List {
            Section("iCloud") { rows(inICloud: true) }
            Section("On this device") { rows(inICloud: false) }
        }
        .navigationTitle("Documents")
        .navigationDestination(for: DocumentItem.self) { DocumentView(item: $0) }
        .toolbar {
            Menu("New", systemImage: "plus") {
                ForEach(StorageKind.allCases) { kind in
                    Button(kind.title) { Task { await lab.createDocument(kind) } }
                }
            }
        }
        .refreshable { lab.refreshDocuments() }
    }

    @ViewBuilder private func rows(inICloud: Bool) -> some View {
        let items = lab.documents.filter { $0.inICloud == inICloud }
        if items.isEmpty {
            Text(inICloud && lab.iCloudRoot == nil ? "iCloud is off for this app" : "None")
                .foregroundStyle(.secondary)
        }
        ForEach(items) { item in
            NavigationLink(value: item) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(lab.summary(of: item)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One document's manual controls: single edits, the sync controls, and its conflicts.
struct DocumentView: View {
    @Environment(Lab.self) private var lab
    let item: DocumentItem

    var body: some View {
        @Bindable var lab = lab
        let busy = lab.isBusy
        Form {
            Section {
                LabeledContent("State", value: lab.summary(of: item))
                if let stamp = lab.lastStamp[item.url] {
                    LabeledContent("Last edit", value: "\(stamp.edit) by \(stamp.deviceName), \(stamp.history.count) in history")
                }
                if item.inICloud {
                    LabeledContent("Sync controls", value: lab.controls[item.url] ?? "checking")
                }
            }
            Section("Edit and save once") {
                HStack {
                    Button("Move") { lab.perform(.move, on: item) }
                    Button("Add photo") { lab.perform(.addPhoto, on: item) }
                    Button("Remove photo") { lab.perform(.removePhoto, on: item) }
                    Button("Close") { lab.perform(.close, on: item) }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                if lab.running == item.url {
                    Button("Stop the editing session", role: .destructive) { lab.stop() }
                } else {
                    Button("Run an editing session on this mix") { lab.runSession(on: item) }.disabled(busy)
                }
            }
            if item.inICloud {
                Section("Sync controls") {
                    HStack {
                        Button("Pause") { Task { await lab.pause(item.url) } }
                        Button("Resume") { Task { await lab.resume(item.url, .preserveLocalChanges) } }
                        Button("Resume, drop mine") { Task { await lab.resume(item.url, .dropLocalChanges) } }
                    }
                    HStack {
                        Button("Upload now") { Task { await lab.uploadNow(item.url, edits: [], failOnConflict: false) } }
                        Button("Fetch latest") { Task { await lab.fetchLatest(item.url) } }
                        Button("Download") { lab.startDownload(item.url) }
                    }
                }
                .buttonStyle(.bordered)
                Section("Conflicts") {
                    let found = lab.conflicts[item.url] ?? []
                    if found.isEmpty { Text("None seen").foregroundStyle(.secondary) }
                    ForEach(found) { info in
                        Text("\(info.file.isEmpty ? "Document" : info.file): saved by \(info.savedBy), holds \(info.edit?.description ?? "no stamp")")
                    }
                    Button("Check my edits") { Task { await lab.checkEdits(item.url) } }
                    if !found.isEmpty {
                        Button("Keep current, remove the others") { lab.keepCurrent(item.url) }
                    }
                }
            } else if lab.iCloudRoot != nil {
                Section {
                    Button("Move to iCloud") { Task { await lab.moveToICloud(item) } }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.name)
        .task(id: item.url) { await lab.refreshControls(item.url) }
    }
}

/// Every edit, newest first, with the CSV export.
struct ResultsView: View {
    @Environment(Lab.self) private var lab

    var body: some View {
        let rows = lab.rows
        List(rows.reversed()) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.edit.description)  \(row.document)").font(.callout.monospaced())
                Text(line(row)).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !row.notes.isEmpty {
                    Text(row.notes.joined(separator: "; ")).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .overlay { if rows.isEmpty { ContentUnavailableView("No edits yet", systemImage: "tablecells") } }
        .navigationTitle("Every edit")
        .toolbar {
            ShareLink(item: CSVExport(text: lab.csv), preview: SharePreview("fsync-lab-results.csv"))
        }
    }

    private func line(_ row: ResultRow) -> String {
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "not yet" }
        let how = [row.storage?.title, row.style?.label, row.sync?.title].compactMap { $0 }.joined(separator: ", ")
        let cost = [row.writeSeconds.map(Lab.ms), row.bytes.map(Lab.bytes)].compactMap { $0 }.joined(separator: ", ")
        let arrivals = row.arrivals.map {
            "\n\(lab.deviceName($0.device)): seen \(seconds($0.listed)), readable \(seconds($0.readable))"
        }
        return "\(how)\nsave \(cost.isEmpty ? "not known here" : cost) · uploaded \(seconds(row.uploaded))" + arrivals.joined()
    }
}

struct LogView: View {
    @Environment(Lab.self) private var lab
    @State private var choosingFolder = false

    var body: some View {
        ScrollViewReader { proxy in
            List(lab.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.at.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))  \(entry.event)\(entry.document.map { "  \($0)" } ?? "")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(entry.detail).font(.callout)
                }
                .id(entry.id)
            }
            .onChange(of: lab.entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .navigationTitle("Log")
        .toolbar {
            Button("Save logs", systemImage: "square.and.arrow.down") {
                if lab.exportFolderName == nil {
                    choosingFolder = true
                } else {
                    Task { await lab.saveLogs() }
                }
            }
            Button("Open folder", systemImage: "folder") { lab.openExportFolder() }
                .disabled(lab.exportFolderName == nil)
            ShareLink(item: Lab.logURL)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            lab.setExportFolder(folder)
            Task { await lab.saveLogs() }
        }
    }
}

/// The results as a CSV file for the share sheet.
struct CSVExport: Transferable {
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
            .suggestedFileName("fsync-lab-results.csv")
    }
}
