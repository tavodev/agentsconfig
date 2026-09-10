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
            CommandGroup(after: .textEditing) {
                Button("Buscar en el archivo") { store.requestFind() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            AppSettingsView()
        }
    }
}

struct AppSettingsView: View {
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("maskSecrets") private var maskSecrets = true
    @AppStorage("watchDebounce") private var debounce = 0.35
    @AppStorage("historyLimit") private var historyLimit = 200

    var body: some View {
        Form {
            Section("Monitoreo") {
                Toggle("Notificación cuando un agente modifica una config", isOn: $notifications)
                LabeledContent("Debounce del watcher") {
                    HStack {
                        Slider(value: $debounce, in: 0.1...2.0, step: 0.05)
                        Text(String(format: "%.2f s", debounce))
                            .font(.caption.monospaced())
                            .frame(width: 52, alignment: .trailing)
                    }
                    .frame(width: 260)
                }
                Stepper("Historial por archivo: \(historyLimit) versiones",
                        value: $historyLimit, in: 10...1000, step: 10)
            }
            Section("Privacidad") {
                Toggle("Enmascarar secretos (api keys, tokens…)", isOn: $maskSecrets)
            }
            Section {
                Button("Abrir carpeta de historial") {
                    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    NSWorkspace.shared.open(base.appendingPathComponent("AgentsConfig/History"))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(4)
    }
}
