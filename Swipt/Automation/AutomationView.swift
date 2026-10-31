import Perception
import SwiftUI

@available(iOS 27, *)
struct AutomationView: View {
    private struct InterfaceRoute: Hashable {
        let name: String
        let entry: SwipletEntry
    }

    @State private var isAddingSwiplet = false
    @State private var swipletToDelete: String?
    @State private var alert: AlertState?

    private let swiplets = SwipletStore.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                swipletsSection
            }
            .navigationDestination(for: InterfaceRoute.self) { route in
                SwipletInterface(name: route.name, entry: route.entry)
            }
            .navigationTitle("Automation")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingSwiplet = true
                    } label: {
                        Label("Add Swiplet", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingSwiplet) {
                NavigationStackCompat {
                    NewSwipletView()
                }
            }
            .onAppear {
                SwipletHost.shared.prepare(swiplets.interfaces)
            }
            .onChange(of: swiplets.interfaces) {
                SwipletHost.shared.prepare(swiplets.interfaces)
            }
            .task { await swiplets.checkForUpdates(of: swiplets.ids) }
            .confirmationDialog(
                "Delete “\(swipletToDelete.map { swiplets.titles[$0] ?? $0 } ?? "")”?",
                isPresented: Binding(get: { swipletToDelete != nil }, set: { if !$0 { swipletToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let swipletToDelete {
                        Task {
                            do {
                                try await swiplets.remove(swipletToDelete)
                            } catch {
                                alert = AlertState(String(localized: "Can’t Delete the Swiplet"), error: error)
                            }
                        }
                    }
                    swipletToDelete = nil
                }
            }
            .alert($alert)
        }
    }

    private var swipletsSection: some View {
        Section {
            if swiplets.ids.isEmpty {
                Text("No Swiplets")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(swiplets.ids, id: \.self, content: swipletRow)
            }
        }
    }

    private func swipletRow(_ name: String) -> some View {
        let service = swiplets.withServices.contains(name) ? swiplets.service(of: name) : nil
        let interface = swiplets.interfaces[name]
        return Group {
            if let interface {
                NavigationLink(value: InterfaceRoute(name: name, entry: interface)) {
                    swipletLabel(name)
                }
            } else if let service {
                Toggle(isOn: Binding(get: { service.enabled }, set: { setService(name, enabled: $0) })) {
                    swipletLabel(name)
                }
            } else {
                swipletLabel(name)
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                swipletToDelete = name
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            ShareLink(item: SwipletFile(id: name), preview: SharePreview(swiplets.titles[name] ?? name)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            if let update = swiplets.updates[name] {
                Button {
                    apply(update)
                } label: {
                    Label("Update", systemImage: "arrow.up")
                }
                .disabled(swiplets.updating.contains(name))
            } else if swiplets.updatable.contains(name) {
                Button {
                    checkForUpdate(name)
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                swipletToDelete = name
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func swipletLabel(_ name: String) -> some View {
        HStack(spacing: 12) {
            SwipletIconImage(icon: swiplets.icons[name] ?? .default, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: swiplets.titles[name] ?? name)
                    .lineLimit(1)
                if swiplets.updating.contains(name) {
                    Text("Updating…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if swiplets.updates[name] != nil {
                    Text("Update Available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setService(_ name: String, enabled: Bool) {
        Task {
            do {
                try await swiplets.setServiceEnabled(name, enabled)
            } catch {
                let title = swiplets.titles[name] ?? name
                alert = AlertState(enabled ? String(localized: "Can’t Turn On “\(title)”") : String(localized: "Can’t Turn Off “\(title)”"), error: error)
            }
        }
    }

    private func apply(_ update: SwipletUpdate) {
        Task {
            do {
                try await swiplets.applyUpdate(update)
            } catch {
                alert = AlertState(String(localized: "Can’t Update the Swiplet"), error: error)
            }
        }
    }

    private func checkForUpdate(_ name: String) {
        Task {
            do {
                let found = try await swiplets.checkForUpdate(of: name)
                if !found {
                    alert = AlertState(title: String(localized: "You’re Up to Date"))
                }
            } catch {
                alert = AlertState(String(localized: "Couldn’t Check for Updates"), error: error)
            }
        }
    }
}
