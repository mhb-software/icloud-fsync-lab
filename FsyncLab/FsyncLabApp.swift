import LabKit
import SwiftUI

@main
struct FsyncLabApp: App {
    @State private var lab = Lab()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(lab)
                .task { await lab.start() }
        }
    }
}

struct RootView: View {
    @Environment(Lab.self) private var lab
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            if let test = lab.activeTest {
                RunningView(test: test)
            } else {
                MainView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // A backgrounded app sees nothing, which explains gaps in the numbers.
            lab.record("app", nil, "\(phase)")
            // Coming back from Settings during the iCloud test: check what changed.
            if phase == .active, let step = lab.switchTest?.step, step != .done {
                Task { await lab.checkICloud(reason: "back in the app") }
            }
        }
    }
}
