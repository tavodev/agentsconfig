import SwiftUI

/// Only one bounded slice reaches NSTextView. The full document remains in the
/// store and is validated/saved by the worker. Ranges expand to whole composed
/// characters so edits cannot split a surrogate pair or grapheme cluster.
struct LargeSourceEditor: View {
    let path: String
    let readOnly: Bool
    @Environment(ConfigStore.self) private var store
    @AppStorage("maskSecrets", store: AppSettings.defaults) private var maskSecrets = true
    @State private var page = 0
    @State private var limitExceeded = false
    static let pageSize = 65_536

    private var source: String { store.text(for: path) }
    private var pages: Int { max(1, ((source as NSString).length + Self.pageSize - 1) / Self.pageSize) }

    static func pageRange(in text: String, page: Int) -> NSRange {
        let string = text as NSString
        let offset = min(max(0, page) * pageSize, string.length)
        let length = min(pageSize, string.length - offset)
        guard length > 0 else { return NSRange(location: offset, length: 0) }
        return string.rangeOfComposedCharacterSequences(for: NSRange(location: offset, length: length))
    }

    static func replacingPage(in text: String, page: Int, with replacement: String) -> String {
        (text as NSString).replacingCharacters(in: pageRange(in: text, page: page), with: replacement)
    }

    var body: some View {
        let range = Self.pageRange(in: source, page: page)
        VStack(spacing: 8) {
            HStack {
                Button(L("Previous page")) { page = max(0, page - 1) }.disabled(page == 0)
                Text(L("Source page %d of %d", page + 1, pages)).font(.caption.monospaced())
                Button(L("Next page")) { page = min(pages - 1, page + 1) }.disabled(page + 1 >= pages)
                Spacer()
            }.padding(.horizontal, 12)
            Text(L("Large-file pages have separate undo stacks. Save reviews and validates the entire file, including other pages."))
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            if limitExceeded {
                Text(L("The pasted text exceeds the page editing limit. Use smaller edits or an external editor."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if readOnly && maskSecrets {
                Text(Secrets.maskedValue).font(.system(.body, design: .monospaced))
                Spacer()
            } else if range.length > Self.pageSize * 2 {
                Text(L("This character sequence is too large to display safely. Use an external editor."))
                Spacer()
            } else {
                if !readOnly {
                    Text(L("Source shows real values, including secrets. Edits are saved exactly as entered."))
                        .font(.caption).foregroundStyle(.orange)
                }
                CodeEditor(documentID: "\(path):page-\(page)", text: Binding(
                    get: { (source as NSString).substring(with: Self.pageRange(in: source, page: page)) },
                    set: { limitExceeded = false; store.updateEdit(path: path, text: Self.replacingPage(in: source, page: page, with: $0)) }
                ), format: store.format(for: path),
                   readOnly: readOnly || store.savingPaths.contains(path) || store.loadingPaths.contains(path),
                   refreshToken: (store.documents[path].map { $0.hash.hashValue ^ $0.loadedAt.hashValue }) ?? 0,
                   findToken: store.findRequest,
                   maximumEditableLength: Self.pageSize * 2, onLimitExceeded: { limitExceeded = true })
            }
        }
        .onChange(of: page) { _, _ in limitExceeded = false }
        .onChange(of: pages) { _, count in page = min(page, count - 1) }
    }
}
