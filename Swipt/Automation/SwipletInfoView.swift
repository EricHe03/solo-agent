import Perception
import SwiftUI

@available(iOS 27, *)
struct SwipletInfoView: View {
    let id: String

    @State private var dataSize: Int64?
    @State private var alert: AlertState?

    private let swiplets = SwipletStore.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    LabeledContentCompat("Name", value: swiplets.titles[id] ?? id)
                    if let version = swiplets.versions[id], !version.isEmpty {
                        LabeledContentCompat("Version", value: version)
                    }
                }
                Section("Data") {
                    LabeledContentCompat {
                        if let dataSize {
                            Text(dataSize.formatted(.byteCount(style: .file)))
                        }
                    } label: {
                        Label("Data Size", systemImage: "internaldrive")
                    }
                    if let dataSize, dataSize > 0 {
                        Button(role: .destructive) {
                            Task { await clearData() }
                        } label: {
                            Label {
                                Text("Clear Data")
                            } icon: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Swiplet Info")
            .navigationBarTitleDisplayMode(.inline)
            .alert($alert)
            .task { await measure() }
        }
    }

    private func measure() async {
        guard let directory = swiplets.dataDirectory(of: id) else { return }
        dataSize = await Task.detached(priority: .utility) { AppDirectory.size(of: directory) }.value
    }

    private func clearData() async {
        dataSize = nil
        do {
            try await swiplets.clearData(of: id)
        } catch {
            alert = AlertState(String(localized: "Couldn’t Clear the Data"), error: error)
        }
        await measure()
    }
}
