import Testing
import SwiftUI
import AppKit

/// F3: the representable's coordinator must always point at the *current*
/// document binding, and undo must be scoped per document.
///
/// Note: `NSViewRepresentable.Context` can't be instantiated outside SwiftUI,
/// so the regression is exercised at the seam SwiftUI uses on every update:
/// `Coordinator.apply(_:)`. Old code had no such refresh — a reused view
/// would keep writing to the previous document's binding.
extension AgentsConfigTestSuite {
@Suite("CodeEditor coordinator", .serialized)
@MainActor
struct CodeEditorTests {

    /// NSTextView only materializes its UndoManager inside a window.
    private func makeTextView() -> (NSTextView, NSWindow) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.allowsUndo = true
        let win = NSWindow(contentRect: tv.frame,
                           styleMask: [.borderless], backing: .buffered,
                           defer: false)
        win.contentView = tv
        return (tv, win)
    }

    @Test func editsAfterDocumentSwitchRouteToNewBinding() {
        var aText = "A"
        var bText = "B"
        let bindingA = Binding(get: { aText }, set: { aText = $0 })
        let bindingB = Binding(get: { bText }, set: { bText = $0 })

        let editorA = CodeEditor(documentID: "a", text: bindingA, format: .json)
        let coord = editorA.makeCoordinator()
        let (tv, _) = makeTextView()
        tv.delegate = coord
        coord.textView = tv

        tv.string = "A edited"
        coord.textDidChange(Notification(name: .init("test")))
        #expect(aText == "A edited")

        // representable reused for another document — the seam updateNSView uses
        coord.apply(CodeEditor(documentID: "b", text: bindingB, format: .json))
        tv.string = "B edited"
        coord.textDidChange(Notification(name: .init("test")))

        #expect(bText == "B edited")
        #expect(aText == "A edited")   // never leaked into A's buffer
    }

    @Test func undoIsClearedOnDocumentSwitch() {
        var aText = "A"
        var bText = "B"
        let bindingA = Binding(get: { aText }, set: { aText = $0 })
        let bindingB = Binding(get: { bText }, set: { bText = $0 })

        let coord = CodeEditor(documentID: "a", text: bindingA,
                               format: .json).makeCoordinator()
        let (tv, _) = makeTextView()
        tv.delegate = coord
        coord.textView = tv

        // produce an undoable change on document A
        tv.insertText(" typed", replacementRange: NSRange(location: 1, length: 0))
        #expect(tv.undoManager?.canUndo == true)

        coord.apply(CodeEditor(documentID: "b", text: bindingB, format: .json))
        #expect(tv.undoManager?.canUndo == false)
    }

    @Test func readOnlyToggleIsAppliedOnUpdate() {
        var text = "x"
        let binding = Binding(get: { text }, set: { text = $0 })
        let coord = CodeEditor(documentID: "a", text: binding,
                               format: .json).makeCoordinator()
        let (tv, _) = makeTextView()
        tv.isEditable = true
        coord.textView = tv

        coord.apply(CodeEditor(documentID: "a", text: binding,
                               format: .json, readOnly: true))
        #expect(tv.isEditable == false)
    }

    @Test func pendingHighlightUsesCurrentFormatAfterSwitch() {
        var aText = "{}"
        var bText = "# t"
        let bindingA = Binding(get: { aText }, set: { aText = $0 })
        let bindingB = Binding(get: { bText }, set: { bText = $0 })
        let coord = CodeEditor(documentID: "a", text: bindingA,
                               format: .json).makeCoordinator()
        coord.apply(CodeEditor(documentID: "b", text: bindingB, format: .markdown))
        #expect(coord.parent.format == .markdown)
        #expect(coord.parent.documentID == "b")
    }
}

}
