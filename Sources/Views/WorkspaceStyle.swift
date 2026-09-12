import SwiftUI

private struct InspectorSheetVisibilityKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

private struct WorkspaceWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1280
}

extension EnvironmentValues {
    var inspectorSheetVisibility: Binding<Bool> {
        get { self[InspectorSheetVisibilityKey.self] }
        set { self[InspectorSheetVisibilityKey.self] = newValue }
    }

    var workspaceWidth: CGFloat {
        get { self[WorkspaceWidthKey.self] }
        set { self[WorkspaceWidthKey.self] = newValue }
    }
}

/// Inspectors must not squeeze the document below a usable reading width.
/// Compact windows present the same content in a dismissible sheet instead.
private struct AdaptiveInspector<Detail: View>: ViewModifier {
    @Environment(\.workspaceWidth) private var width
    @Environment(\.inspectorSheetVisibility) private var sheetVisible
    @Environment(ConfigStore.self) private var store
    @Binding var presented: Bool
    let panelThreshold: CGFloat
    let title: String
    @ViewBuilder var detail: () -> Detail

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: Binding(
                get: { presented && width >= panelThreshold },
                set: { if width >= panelThreshold { presented = $0 } }
            )) {
                detail().inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
            .sheet(isPresented: Binding(
                get: { presented && width < panelThreshold },
                set: { if width < panelThreshold { presented = $0 } }
            ), onDismiss: { sheetVisible.wrappedValue = false }) {
                VStack(spacing: 0) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        Button(L("Done")) { presented = false }
                            .keyboardShortcut(.cancelAction)
                    }.padding(16)
                    Divider()
                    detail()
                }
                .frame(width: 520, height: 560)
                .onAppear { sheetVisible.wrappedValue = true }
            }
            .onChange(of: reviewRequested) { _, requested in
                if requested && sheetVisible.wrappedValue { presented = false }
            }
    }

    private var reviewRequested: Bool {
        store.pendingRestore != nil || store.pendingMcpReview != nil
            || store.pendingSaveReview != nil || store.actionError != nil
    }
}

extension View {
    func adaptiveInspector<Detail: View>(isPresented: Binding<Bool>, title: String,
                                        panelThreshold: CGFloat = 1450,
                                        @ViewBuilder content: @escaping () -> Detail) -> some View {
        modifier(AdaptiveInspector(presented: isPresented, panelThreshold: panelThreshold,
                                   title: title, detail: content))
    }
}

private struct PreviewReducedTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var previewReducedTransparency: Bool {
        get { self[PreviewReducedTransparencyKey.self] }
        set { self[PreviewReducedTransparencyKey.self] = newValue }
    }
}

/// App-owned status surfaces honor the real accessibility preference; the
/// isolated preview can exercise this branch without changing macOS settings.
struct WorkspaceBarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.previewReducedTransparency) private var previewReducedTransparency

    var body: some View {
        if reduceTransparency || previewReducedTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.bar)
        }
    }
}
