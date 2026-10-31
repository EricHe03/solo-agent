import SwiftUI
import UniformTypeIdentifiers

@available(iOS 27, *)
struct NewSwipletView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isPickingFile = false
    @State private var isImporting = false
    @State private var isImported = false
    @State private var alert: AlertState?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    OfficialSwipletsView(isImported: $isImported)
                } label: {
                    Label("Official Swiplets", systemImage: "checkmark.seal")
                }
            }
            Section {
                Button {
                    isPickingFile = true
                } label: {
                    Label("Import from File", systemImage: "doc.badge.plus")
                }
                NavigationLink {
                    ImportFromURLView(isImported: $isImported)
                } label: {
                    Label("Import from URL", systemImage: "link.badge.plus")
                }
            }
        }
        .disabled(isImporting)
        .overlay {
            if isImporting {
                ProgressView()
            }
        }
        .navigationTitle("Add Swiplet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.swiplet, .zip]) { result in
            switch result {
            case .success(let file):
                importFile(file)
            case .failure(let error):
                alert = AlertState(String(localized: "Can’t Open the File"), error: error)
            }
        }
        .onChange(of: isImported) {
            if isImported {
                dismiss()
            }
        }
        .alert($alert)
    }

    private func importFile(_ file: URL) {
        isImporting = true
        Task {
            do {
                try await SwipletStore.shared.importSwiplet(from: file)
                isImported = true
            } catch {
                alert = AlertState(String(localized: "Can’t Import the Swiplet"), error: error)
            }
            isImporting = false
        }
    }
}

@available(iOS 27, *)
private struct ImportFromURLView: View {
    @Binding var isImported: Bool

    @State private var url = ""
    @State private var isImporting = false
    @State private var alert: AlertState?

    var body: some View {
        Form {
            Section {
                LabeledContentCompat("URL") {
                    TextField("URL", text: $url, prompt: Text("Required"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .onSubmit(importSwiplet)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Supported formats:")
                    VStack(alignment: .leading, spacing: 2) {
                        BulletText("ZIP files")
                        BulletText("ZIP files with a single top-level folder")
                        BulletText("ZIP files with the !/ syntax to select a subfolder")
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .disabled(isImporting)
        .navigationTitle("Import from URL")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isImporting {
                    ProgressView()
                } else {
                    Button("Import", action: importSwiplet)
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert($alert)
    }

    private func importSwiplet() {
        guard !isImporting, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isImporting = true
        Task {
            do {
                try await SwipletStore.shared.importSwiplet(downloadingFrom: url)
                isImported = true
            } catch {
                alert = AlertState(String(localized: "Can’t Import the Swiplet"), error: error)
            }
            isImporting = false
        }
    }
}

private struct BulletText: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
            Text(text)
        }
    }
}
