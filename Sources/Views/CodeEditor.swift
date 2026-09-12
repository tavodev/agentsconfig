import SwiftUI
import AppKit

/// Native code editor: NSTextView + line-number ruler + lightweight
/// regex highlighting for JSON/JSONC/TOML/Markdown/shell.
struct CodeEditor: NSViewRepresentable {
    var documentID: String      // which document the binding edits
    @Binding var text: String
    var format: ConfigFormat
    var readOnly: Bool = false
    var refreshToken: Int = 0   // bump to force reload after external writes
    var findToken: Int = 0      // bump to open the find bar (⌘F)
    var maximumEditableLength: Int? = nil
    var onLimitExceeded: (@MainActor () -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let textStorage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer()
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textStorage.addLayoutManager(layout)

        let tv = CodeTextView(frame: .zero, textContainer: container)
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .labelColor
        tv.backgroundColor = .clear
        tv.isEditable = !readOnly
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.setAccessibilityIdentifier("source-editor")
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = context.coordinator
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)

        let ruler = LineNumberRulerView(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.rulersVisible = true
        scroll.documentView = tv

        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        tv.string = text
        Highlighter.apply(to: tv.textStorage!, format: format)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // SwiftUI may reuse this view for a different document — refresh the
        // coordinator *before* anything else reads stale state.
        context.coordinator.apply(self)
        guard let tv = context.coordinator.textView else { return }
        tv.isEditable = !readOnly
        if tv.string != text && !context.coordinator.isEditing {
            let selected = tv.selectedRange()
            tv.string = text
            Highlighter.apply(to: tv.textStorage!, format: format)
            tv.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
            context.coordinator.ruler?.needsDisplay = true
        }
        if context.coordinator.lastToken != refreshToken {
            context.coordinator.lastToken = refreshToken
            if tv.string != text {
                tv.string = text
                Highlighter.apply(to: tv.textStorage!, format: format)
            }
        }
        if context.coordinator.lastFindToken != findToken {
            context.coordinator.lastFindToken = findToken
            if findToken > 0 {
                let sender = NSButton()
                sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                tv.performFindPanelAction(sender)
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        var isEditing = false
        var lastToken = 0
        var lastFindToken = 0
        private var highlightWork: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

        /// Point the coordinator at the representable's current state.
        /// Called from `updateNSView` on every SwiftUI update, so a reused
        /// view never writes into the previous document's binding. On a
        /// document switch it cancels pending highlight work, resets editing
        /// state and clears the undo stack — undo must be per-document.
        @MainActor
        func apply(_ parent: CodeEditor) {
            let switched = parent.documentID != self.parent.documentID
            self.parent = parent
            if switched {
                highlightWork?.cancel()
                isEditing = false
                textView?.undoManager?.removeAllActions()
            }
            textView?.isEditable = !parent.readOnly
        }

        func textDidBeginEditing(_ n: Notification) { isEditing = true }
        func textDidEndEditing(_ n: Notification) { isEditing = false }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let limit = parent.maximumEditableLength else { return true }
            let length = (textView.string as NSString).length - affectedCharRange.length
                + ((replacementString ?? "") as NSString).length
            guard length <= limit else { parent.onLimitExceeded?(); return false }
            return true
        }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            ruler?.needsDisplay = true
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let storage = self.textView?.textStorage else { return }
                Highlighter.apply(to: storage, format: self.parent.format)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
}

/// NSTextView subclass: Cmd+S posts to a handler the app can hook.
final class CodeTextView: NSTextView {
    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertTab(_:)) {
            insertText("  ", replacementRange: selectedRange())  // 2 spaces for tabs
            return
        }
        super.doCommand(by: selector)
    }
}

// MARK: - Line numbers

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 38
    }
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let bg = NSColor.controlBackgroundColor.withAlphaComponent(0.5)
        bg.setFill()
        rect.fill()

        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let text = tv.string as NSString
        var lineNumber = text.substring(to: min(charRange.location, text.length))
            .components(separatedBy: "\n").count

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        var index = charRange.location
        while index < NSMaxRange(charRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let gRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let bounds = lm.boundingRect(forGlyphRange: gRange, in: tc)
            let y = bounds.minY + tv.textContainerInset.height - scrollView!.contentView.bounds.minY
            let s = "\(lineNumber)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attrs)
            index = NSMaxRange(lineRange)
            lineNumber += 1
            if bounds.minY - visible.minY > visible.height { break }
        }
    }
}

// MARK: - Highlighting

enum Highlighter {
    private static let keyColor = NSColor.systemIndigo
    private static let stringColor = NSColor.systemRed
    private static let numberColor = NSColor.systemBlue
    private static let literalColor = NSColor.systemPurple
    private static let commentColor = NSColor.tertiaryLabelColor
    private static let sectionColor = NSColor.systemTeal
    private static let headingColor = NSColor.systemPurple

    static func apply(to storage: NSTextStorage, format: ConfigFormat) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0, full.length < 600_000 else { return }

        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ], range: full)

        switch format {
        case .json, .jsonc: highlightJSON(storage)
        case .toml: highlightTOML(storage)
        case .markdown: highlightMarkdown(storage)
        case .shell, .dsl: highlightShell(storage)
        default: break
        }
        storage.endEditing()
    }

    private static func paint(_ storage: NSTextStorage, _ pattern: String,
                              _ color: NSColor, group: Int = 0, options: NSRegularExpression.Options = []) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let s = storage.string as NSString
        let range = NSRange(location: 0, length: s.length)
        re.enumerateMatches(in: storage.string, options: [], range: range) { m, _, _ in
            guard let m, m.numberOfRanges > group else { return }
            storage.addAttribute(.foregroundColor, value: color, range: m.range(at: group))
        }
    }

    private static func highlightJSON(_ s: NSTextStorage) {
        paint(s, #"//[^\n]*"# , commentColor)
        paint(s, #"/\*.*?\*/"#, commentColor, options: [.dotMatchesLineSeparators])
        paint(s, #""(?:\\.|[^"\\])*"(?=\s*:)"#, keyColor)
        paint(s, #""(?:\\.|[^"\\])*"(?!\s*:)"#, stringColor)
        paint(s, #"(?<![\w"])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#, numberColor)
        paint(s, #"\b(?:true|false|null)\b"#, literalColor)
    }

    private static func highlightTOML(_ s: NSTextStorage) {
        paint(s, #"#[^\n]*"#, commentColor)
        paint(s, #"^\s*\[+[^\]\n]+\]+"#, sectionColor, options: [.anchorsMatchLines])
        paint(s, #"^[A-Za-z0-9_.\"-]+(?=\s*=)"#, keyColor, options: [.anchorsMatchLines])
        paint(s, #""(?:\\.|[^"\\])*"|'[^'\n]*'|"""#, stringColor)
        paint(s, #"(?<![\w"-])-?\d+(?:\.\d+)?"#, numberColor)
        paint(s, #"\b(?:true|false)\b"#, literalColor)
    }

    private static func highlightMarkdown(_ s: NSTextStorage) {
        paint(s, #"^#{1,6}[^\n]*"#, headingColor, options: [.anchorsMatchLines])
        paint(s, #"`[^`\n]+`"#, stringColor)
        paint(s, #"\*\*[^*\n]+\*\*"#, keyColor)
        paint(s, #"\[[^\]\n]+\]\([^\)\n]+\)"#, numberColor)
    }

    private static func highlightShell(_ s: NSTextStorage) {
        paint(s, #"#[^\n]*"#, commentColor)
        paint(s, #""(?:\\.|[^"\\])*"|'[^'\n]*'"#, stringColor)
        paint(s, #"\$[A-Za-z_{][A-Za-z0-9_}]*"#, literalColor)
    }
}
