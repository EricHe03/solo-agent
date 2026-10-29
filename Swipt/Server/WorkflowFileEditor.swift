import LibSwipt
import Runestone
import SwiftUI
import TreeSitterJSONRunestone
import TreeSitterJavaScriptRunestone
import UIKit

@available(iOS 27, *)
struct WorkflowFileEditor: View {
    let file: WorkflowFileItem

    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: WorkflowFileEditorModel

    init(file: WorkflowFileItem) {
        self.file = file
        _editor = State(initialValue: WorkflowFileEditorModel(file: file))
    }

    var body: some View {
        @Bindable var editor = editor
        Group {
            if let text = editor.initialText {
                CodeTextView(editor: editor, text: text)
                    .safeAreaInset(edge: .bottom) {
                        EditorBar(editor: editor)
                    }
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: editor.load)
        .onDisappear(perform: editor.save)
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                editor.save()
            }
        }
        .alert($editor.alert)
    }
}

nonisolated private enum EditorLanguage {
    case javaScript
    case json
    case plainText

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "js", "mjs", "cjs":
            self = .javaScript
        case "json":
            self = .json
        default:
            self = .plainText
        }
    }

    var treeSitter: TreeSitterLanguage? {
        switch self {
        case .javaScript: .javaScript
        case .json: .json
        case .plainText: nil
        }
    }

    var symbols: [String] {
        switch self {
        case .javaScript: ["(", ")", "{", "}", "[", "]", ";", "=", "=>", ".", ",", ":", "\"", "'", "`", "!", "?", "&", "|", "<", ">", "+", "-", "*", "/", "$"]
        case .json: ["\"", ":", ",", "{", "}", "[", "]", "true", "false", "null"]
        case .plainText: []
        }
    }

    var characterPairs: [any CharacterPair] {
        switch self {
        case .javaScript: [Pair("(", ")"), Pair("{", "}"), Pair("[", "]"), Pair("\"", "\""), Pair("'", "'"), Pair("`", "`")]
        case .json: [Pair("{", "}"), Pair("[", "]"), Pair("\"", "\"")]
        case .plainText: []
        }
    }

    private struct Pair: CharacterPair {
        let leading: String
        let trailing: String

        init(_ leading: String, _ trailing: String) {
            self.leading = leading
            self.trailing = trailing
        }
    }
}

@available(iOS 27, *)
@Observable
private final class WorkflowFileEditorModel: TextViewDelegate {
    let file: WorkflowFileItem
    let language: EditorLanguage
    var initialText: String?
    var canUndo = false
    var canRedo = false
    var problem: String?
    var alert: AlertState?

    @ObservationIgnored weak var textView: TextView?
    @ObservationIgnored private var isModified = false
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(file: WorkflowFileItem) {
        self.file = file
        language = EditorLanguage(file.url)
    }

    func load() {
        guard initialText == nil else { return }
        do {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            initialText = text
            check(text)
        } catch {
            alert = AlertState(String(localized: "Can’t Open the File"), error: error)
        }
    }

    func textViewDidChange(_ textView: TextView) {
        isModified = true
        updateUndoState()
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(seconds: 1)
            guard !Task.isCancelled else { return }
            save()
            check(textView.text)
        }
    }

    func save() {
        guard isModified, let textView else { return }
        pending?.cancel()
        do {
            try Data(textView.text.utf8).write(to: file.url)
            isModified = false
        } catch {
            alert = AlertState(String(localized: "Can’t Save the File"), error: error)
        }
    }

    func undo() {
        textView?.undoManager?.undo()
        updateUndoState()
    }

    func redo() {
        textView?.undoManager?.redo()
        updateUndoState()
    }

    func find() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func insert(_ symbol: String) {
        textView?.insertText(symbol)
    }

    func format() {
        guard let textView else { return }
        let text = textView.text
        var error: NSError?
        let formatted = LibSwiptFormatJSON(text, &error)
        if let error {
            problem = error.localizedDescription
            return
        }
        problem = nil
        if formatted != text {
            textView.replace(NSRange(location: 0, length: (text as NSString).length), withText: formatted)
        }
    }

    private func check(_ text: String) {
        guard language == .json, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = nil
            return
        }
        var error: NSError?
        _ = LibSwiptFormatJSON(text, &error)
        problem = error?.localizedDescription
    }

    private func updateUndoState() {
        canUndo = textView?.undoManager?.canUndo ?? false
        canRedo = textView?.undoManager?.canRedo ?? false
    }
}

@available(iOS 27, *)
private struct CodeTextView: UIViewRepresentable {
    let editor: WorkflowFileEditorModel
    let text: String

    func makeUIView(context: Context) -> TextView {
        let textView = TextView()
        textView.backgroundColor = .systemBackground
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .always
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line
        textView.isFindInteractionEnabled = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.characterPairs = editor.language.characterPairs
        if let language = editor.language.treeSitter {
            textView.setState(TextViewState(text: text, language: language))
            textView.isCodeFoldingEnabled = true
        } else {
            textView.setState(TextViewState(text: text))
        }
        switch textView.detectIndentStrategy() {
        case .tab:
            textView.indentStrategy = .tab(length: 2)
        case .space(let length):
            textView.indentStrategy = .space(length: length)
        case .unknown:
            textView.indentStrategy = .space(length: 2)
        }
        textView.editorDelegate = editor
        editor.textView = textView
        return textView
    }

    func updateUIView(_ textView: TextView, context: Context) {}
}

@available(iOS 27, *)
private struct EditorBar: View {
    let editor: WorkflowFileEditorModel

    var body: some View {
        VStack(spacing: 8) {
            if let problem = editor.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    action("Undo", systemImage: "arrow.uturn.backward", perform: editor.undo)
                        .disabled(!editor.canUndo)
                    action("Redo", systemImage: "arrow.uturn.forward", perform: editor.redo)
                        .disabled(!editor.canRedo)
                    action("Find", systemImage: "magnifyingglass", perform: editor.find)
                    if editor.language == .json {
                        action("Format", systemImage: "text.alignleft", perform: editor.format)
                    }
                    if !editor.language.symbols.isEmpty {
                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 6)
                    }
                    ForEach(editor.language.symbols, id: \.self) { symbol in
                        Button {
                            editor.insert(symbol)
                        } label: {
                            Text(verbatim: symbol)
                                .font(.body.monospaced())
                                .frame(minWidth: 36, minHeight: 44)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .buttonStyle(.borderless)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func action(_ title: LocalizedStringKey, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
    }
}
