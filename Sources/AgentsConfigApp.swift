import SwiftUI

@main
struct AgentsConfigApp: App {
    @State private var store = ConfigStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 1020, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Guardar") { store.saveSelected() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!store.canSaveSelected)
            }
        }
    }
}
