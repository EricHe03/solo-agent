import Perception
import SwiftUI

@available(iOS 27, *)
struct RepositoryView: View {
    let url: String
    @Binding var isImported: Bool

    @State private var alert: AlertState?

    private let swiplets = SwipletStore.shared

    var body: some View {
        WithPerceptionTracking {
            let repository = swiplets.repository(url)
            Form {
                if let repository, !repository.swiplets.isEmpty {
                    Section {
                        ForEach(repository.swiplets) { swiplet in
                            row(swiplet, in: repository)
                        }
                    }
                } else {
                    Text("No Swiplets in This Repository")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Text(verbatim: repository?.name ?? ""))
            .refreshable { await refresh(force: true) }
            .task { await refresh(force: false) }
            .alert($alert)
        }
    }

    private func refresh(force: Bool) async {
        do {
            try await swiplets.refreshRepository(url, force: force)
        } catch {
            alert = AlertState(String(localized: "Couldn’t Refresh the Repository"), error: error)
        }
    }

    private func row(_ swiplet: RepositorySwiplet, in repository: Repository) -> some View {
        HStack(spacing: 12) {
            SwipletIconImage(icon: swiplet.swipletIcon, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: swiplet.title)
                    .lineLimit(1)
                if !swiplet.description.isEmpty {
                    Text(verbatim: swiplet.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !swiplet.version.isEmpty {
                    Text(verbatim: swiplet.version)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing(swiplet, in: repository)
        }
    }

    @ViewBuilder
    private func trailing(_ swiplet: RepositorySwiplet, in repository: Repository) -> some View {
        if swiplets.updating.contains(swiplet.id) {
            ProgressView()
        } else if !swiplets.ids.contains(swiplet.id) {
            Button("Add") { install(swiplet, from: repository) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else if swiplets.hasNewer(swiplet) {
            Button("Update") { install(swiplet, from: repository) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
        }
    }

    private func install(_ swiplet: RepositorySwiplet, from repository: Repository) {
        Task {
            do {
                try await swiplets.install(swiplet, from: repository)
                isImported = true
            } catch {
                alert = AlertState(String(localized: "Can’t Add the Swiplet"), error: error)
            }
        }
    }
}

@available(iOS 27, *)
struct AddRepositoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var isAdding = false
    @State private var alert: AlertState?

    var body: some View {
        Form {
            TextField("URL", text: $url)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(add)
        }
        .disabled(isAdding)
        .navigationTitle("Add Repository")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isAdding {
                    ProgressView()
                } else {
                    Button("Add", action: add)
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert($alert)
    }

    private func add() {
        guard !isAdding, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAdding = true
        Task {
            do {
                try await SwipletStore.shared.addRepository(url)
                dismiss()
            } catch {
                alert = AlertState(String(localized: "Can’t Add the Repository"), error: error)
            }
            isAdding = false
        }
    }
}
