import SwiftUI
import AppKit

@main
struct AgentsConfigApp: App {
    @State private var store = ConfigStore()
    @AppStorage("menuBarExtra") private var menuBarExtra = true
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 1020, minHeight: 640)
                .onAppear { applyAppearance() }
                .onChange(of: appearance) { applyAppearance() }
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
            CommandGroup(after: .toolbar) {
                ForEach(EditorTab.allCases, id: \.self) { t in
                    Button(t.rawValue) { store.requestedTab = t }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(EditorTab.allCases.firstIndex(of: t)! + 1)")),
                            modifiers: .command
                        )
                }
                Divider()
                Button(store.showInspector ? "Ocultar inspector" : "Mostrar inspector") {
                    store.showInspector.toggle()
                }
                .keyboardShortcut("0", modifiers: [.option, .command])
            }
        }

        MenuBarExtra(isInserted: $menuBarExtra) {
            MenuBarView()
                .environment(store)
        } label: {
            let pending = store.externalChanges.count
            Image(systemName: pending > 0 ? "bolt.horizontal.fill" : "slider.horizontal.3")
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
        }
    }

    private func applyAppearance() {
        NSApp.appearance = AppSettings.appearance
    }
}

struct AppSettingsView: View {
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("maskSecrets") private var maskSecrets = true
    @AppStorage("watchDebounce") private var debounce = 0.35
    @AppStorage("historyLimit") private var historyLimit = 200
    @AppStorage("menuBarExtra") private var menuBarExtra = true
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section("Apariencia") {
                Picker("Tema", selection: $appearance) {
                    Text("Sistema").tag("system")
                    Text("Claro").tag("light")
                    Text("Oscuro").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("Icono en la barra de menús", isOn: $menuBarExtra)
            }
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
