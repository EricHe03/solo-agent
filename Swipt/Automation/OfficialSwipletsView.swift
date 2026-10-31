import Perception
import SwiftUI

@available(iOS 27, *)
struct OfficialSwipletsView: View {
    @Binding var isImported: Bool

    @State private var loadError: String?
    @State private var alert: AlertState?

    private let swiplets = SwipletStore.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                if swiplets.officialSwiplets.isEmpty {
                    Section {
                        if swiplets.isLoadingOfficialSwiplets {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        } else if let loadError {
                            Text(verbatim: loadError)
                                .foregroundStyle(.secondary)
                            Button("Try Again") {
                                Task { await load(force: true) }
                            }
                        } else {
                            Text("No Official Swiplets")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        ForEach(swiplets.officialSwiplets, content: row)
                    } footer: {
                        Text("Official swiplets are made by the Swipt team and update automatically.")
                    }
                }
            }
            .navigationTitle("Official Swiplets")
            .refreshable { await load(force: true) }
            .task { await load(force: false) }
            .alert($alert)
        }
    }

    private func load(force: Bool) async {
        do {
            try await swiplets.loadOfficialSwiplets(force: force)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func row(_ swiplet: OfficialSwiplet) -> some View {
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
            trailing(swiplet)
        }
    }

    @ViewBuilder
    private func trailing(_ swiplet: OfficialSwiplet) -> some View {
        if swiplets.updating.contains(swiplet.id) {
            ProgressView()
        } else if !swiplets.ids.contains(swiplet.id) {
            Button("Add") { install(swiplet) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else if swiplets.hasNewerOfficial(swiplet) {
            Button("Update") { install(swiplet) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        } else {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
        }
    }

    private func install(_ swiplet: OfficialSwiplet) {
        Task {
            do {
                try await swiplets.installOfficial(swiplet)
                isImported = true
            } catch {
                alert = AlertState(String(localized: "Can’t Add the Swiplet"), error: error)
            }
        }
    }
}
