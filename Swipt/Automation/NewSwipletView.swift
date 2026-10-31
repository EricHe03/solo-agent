import Perception
import SwiftUI
import UniformTypeIdentifiers

@available(iOS 27, *)
struct NewSwipletView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isPickingFile = false
    @State private var isImporting = false
    @State private var isImported = false
    @State private var alert: AlertState?

    private let swiplets = SwipletStore.shared

    var body: some View {
        WithPerceptionTracking {
            form
        }
    }

    private var form: some View {
        Form {
            Section("Repository") {
                NavigationLink {
                    AddRepositoryView()
                } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                ForEach(swiplets.repositories) { repository in
                    NavigationLink {
                        RepositoryView(url: repository.url, isImported: $isImported)
                    } label: {
                        Label {
                            Text(verbatim: repository.title)
                                .lineLimit(1)
                        } icon: {
                            SwipletIconImage(icon: repository.swipletIcon, size: 29)
                        }
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        swiplets.removeRepository(swiplets.repositories[offset].url)
                    }
                }
            }
            Section("Manual") {
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
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.swiplet]) { result in
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
            TextField("URL", text: $url)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(importSwiplet)
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
