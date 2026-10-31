import SwiftUI

@main
struct LoqApp: App {
    @NSApplicationDelegateAdaptor(LoqDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        Window("Loq", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 680)
                .task { model.start() }
                .onDisappear { model.stop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stop()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.capture.cancel()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.pauseSensors() }
                }
        }
        .windowResizability(.contentMinSize)
    }
}

private final class LoqDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
