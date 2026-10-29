import Perception
import SwiftUI

@available(iOS 27, *)
struct AutomationView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isCreatingWorkflow = false
    @State private var workflowToEdit: String?
    @State private var workflowToRename: String?
    @State private var newName = ""
    @State private var workflowChoosingIcon: String?
    @State private var workflowToDelete: String?
    @State private var completedWorkflows: Set<String> = []
    @State private var alert: AlertState?

    private let workflows = WorkflowStore.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                workflowsSection
            }
            .navigationTitle("Automation")
            .modifier(ServerScreen())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreatingWorkflow = true
                    } label: {
                        Label("New Workflow", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isCreatingWorkflow) {
                NavigationStackCompat {
                    NewWorkflowView()
                }
            }
            .navigationDestination(item: $workflowToEdit) { name in
                WorkflowView(name: name)
            }
            .onAppear { workflows.reload() }
            .task { await workflows.checkForUpdates(of: workflows.names) }
            .refreshable { workflows.reload() }
            .alert(
                "Rename Workflow",
                isPresented: Binding(get: { workflowToRename != nil }, set: { if !$0 { workflowToRename = nil } }),
                presenting: workflowToRename
            ) { name in
                TextField("Name", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard newName.trimmingCharacters(in: .whitespacesAndNewlines) != name else { return }
                    do {
                        _ = try workflows.rename(name, to: newName)
                    } catch {
                        alert = AlertState(String(localized: "Can’t Rename the Workflow"), error: error)
                    }
                }
            }
            .confirmationDialog(
                "Delete “\(workflowToDelete ?? "")”?",
                isPresented: Binding(get: { workflowToDelete != nil }, set: { if !$0 { workflowToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let workflowToDelete {
                        do {
                            try workflows.remove(workflowToDelete)
                        } catch {
                            alert = AlertState(String(localized: "Can’t Delete the Workflow"), error: error)
                        }
                    }
                    workflowToDelete = nil
                }
            }
            .alert($alert)
        }
    }

    private var workflowsSection: some View {
        Section("Workflows") {
            if workflows.names.isEmpty {
                Text("No Workflows")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 200 : 150), spacing: 12)], spacing: 12) {
                    ForEach(workflows.names, id: \.self, content: workflowTile)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private func workflowTile(_ name: String) -> some View {
        let isRunning = workflows.isRunning(name)
        let toggle = {
            if isRunning {
                workflows.stop(name)
            } else {
                run(name)
            }
        }
        return Button(action: toggle) {
            WorkflowTile(name: name, icon: workflows.icons[name] ?? .default)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text("Running"), isEnabled: isRunning)
        .accessibilityActions {
            if let update = workflows.updates[name], !workflows.updating.contains(name) {
                Button("Update") { apply(update) }
            }
            Button("Edit") { workflowToEdit = name }
            Button("Duplicate") { duplicate(name) }
            Button("Delete") { workflowToDelete = name }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: -WorkflowRunButton.hitPadding) {
                if let update = workflows.updates[name] {
                    WorkflowUpdateButton(ring: (workflows.icons[name] ?? .default).palette.top, isUpdating: workflows.updating.contains(name)) {
                        apply(update)
                    }
                }
                WorkflowRunButton(status: runStatus(of: name), action: toggle)
            }
            .padding(.top, 14.5 - WorkflowRunButton.hitPadding)
            .padding(.trailing, 15.5 - WorkflowRunButton.hitPadding)
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: WorkflowTile.cornerRadius, style: .continuous))
        .contextMenu {
            Section {
                Button {
                    workflowToEdit = name
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                Button {
                    newName = name
                    workflowToRename = name
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(isRunning)
                Button {
                    workflowChoosingIcon = name
                } label: {
                    Label("Choose Icon", systemImage: "square.dashed")
                }
                ShareLink(item: WorkflowFile(name: name), preview: SharePreview(name)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if let update = workflows.updates[name] {
                    Button {
                        apply(update)
                    } label: {
                        Label("Update", systemImage: "arrow.up")
                    }
                    .disabled(workflows.updating.contains(name))
                } else if workflows.updatable.contains(name) {
                    Button {
                        checkForUpdate(name)
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.clockwise")
                    }
                }
            }
            Button {
                duplicate(name)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                workflowToDelete = name
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .popover(isPresented: Binding(get: { workflowChoosingIcon == name }, set: { if !$0 { workflowChoosingIcon = nil } })) {
            WorkflowIconPicker(icon: icon(of: name))
        }
    }

    private func runStatus(of name: String) -> WorkflowRunButton.Status {
        if workflows.isRunning(name) {
            return workflows.isWaiting(name) ? .waiting : .running
        }
        return completedWorkflows.contains(name) ? .completed : .idle
    }

    private func icon(of name: String) -> Binding<WorkflowIcon> {
        Binding {
            workflows.icons[name] ?? .default
        } set: { icon in
            do {
                try workflows.setIcon(icon, for: name)
            } catch {
                alert = AlertState(String(localized: "Can’t Change the Icon"), error: error)
            }
        }
    }

    private func run(_ name: String) {
        Task {
            switch await workflows.run(name) {
            case .failure(let error):
                alert = AlertState(String(localized: "Can’t Run “\(name)”"), error: error)
                return
            case .success:
                break
            case nil:
                return
            }
            completedWorkflows.insert(name)
            try? await Task.sleep(seconds: 1)
            completedWorkflows.remove(name)
        }
    }

    private func apply(_ update: WorkflowUpdate) {
        Task {
            do {
                try await workflows.applyUpdate(update)
            } catch {
                alert = AlertState(String(localized: "Can’t Update the Workflow"), error: error)
            }
        }
    }

    private func checkForUpdate(_ name: String) {
        Task {
            do {
                try await workflows.checkForUpdate(of: name)
                if workflows.updates[name] == nil {
                    alert = AlertState(title: String(localized: "You’re Up to Date"))
                }
            } catch {
                alert = AlertState(String(localized: "Couldn’t Check for Updates"), error: error)
            }
        }
    }

    private func duplicate(_ name: String) {
        do {
            try workflows.duplicate(name)
        } catch {
            alert = AlertState(String(localized: "Can’t Duplicate the Workflow"), error: error)
        }
    }
}

@available(iOS 27, *)
private struct WorkflowTile: View {
    static let cornerRadius: CGFloat = 24.5

    let name: String
    let icon: WorkflowIcon

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkflowIconGlyph(symbol: icon.symbol, pointSize: 26)
                .foregroundStyle(.white.opacity(0.88))
                .frame(height: 31)
            Spacer(minLength: 8)
            Text(verbatim: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(EdgeInsets(top: 12.5, leading: 16, bottom: 14.5, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(icon.gradient, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }
}

@available(iOS 27, *)
private struct WorkflowRunButton: View {
    enum Status {
        case idle
        case running
        case waiting
        case completed
    }

    static let size: CGFloat = 29
    static let hitPadding: CGFloat = 7.5

    let status: Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white.opacity(17 / 255))
                    .blendMode(.plusLighter)
                switch status {
                case .idle:
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .offset(x: 0.5)
                case .running:
                    TimelineView(.animation) { context in
                        Circle()
                            .inset(by: 1.25)
                            .trim(from: 0, to: 0.7)
                            .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360 - 90))
                    }
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(.white.opacity(0.6))
                        .frame(width: 8, height: 8)
                case .waiting:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                case .completed:
                    Image(systemName: "checkmark")
                        .font(.system(size: 13.5, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .padding(Self.hitPadding)
            .contentShape(.rect)
            .animation(.easeInOut(duration: 0.2), value: status)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status == .running || status == .waiting ? Text("Stop") : Text("Run"))
    }
}

@available(iOS 27, *)
private struct WorkflowUpdateButton: View {
    let ring: Color
    let isUpdating: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white.opacity(17 / 255))
                    .blendMode(.plusLighter)
                if isUpdating {
                    TimelineView(.animation) { context in
                        Circle()
                            .inset(by: 1.25)
                            .trim(from: 0, to: 0.7)
                            .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360 - 90))
                    }
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .overlay(alignment: .topTrailing) {
                if !isUpdating {
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .padding(2)
                        .background(ring, in: Circle())
                        .offset(x: 3, y: -3)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isUpdating)
            .foregroundStyle(.white)
            .frame(width: WorkflowRunButton.size, height: WorkflowRunButton.size)
            .padding(WorkflowRunButton.hitPadding)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .accessibilityLabel(Text("Update"))
    }
}
