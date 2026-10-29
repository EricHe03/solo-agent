import LibSwipt
import Perception
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

@available(iOS 27, *)
struct WorkflowView: View {
    @State private var name: String
    @State private var sourceFiles: [WorkflowFileItem] = []
    @State private var dataFiles: [WorkflowFileItem] = []
    @State private var editing: WorkflowFileItem?
    @State private var previewing: URL?
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isCreatingFile = false
    @State private var newFileName = ""
    @State private var isChoosingIcon = false
    @State private var isDeletingData = false
    @State private var alert: AlertState?

    private let workflows = WorkflowStore.shared

    init(name: String) {
        _name = State(initialValue: name)
    }

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    ForEach(sourceFiles) { file in
                        fileRow(file)
                            .deleteDisabled(file.name == LibSwiptWorkflowEntryFile)
                    }
                    .onDelete { offsets in
                        delete(offsets.map { sourceFiles[$0] })
                    }
                } header: {
                    sectionHeader("Source Code") {
                        Button {
                            newFileName = ""
                            isCreatingFile = true
                        } label: {
                            Label("New File", systemImage: "plus")
                        }
                    }
                }
                Section {
                    if dataFiles.isEmpty {
                        Text("No Data")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dataFiles, content: fileRow)
                            .onDelete { offsets in
                                delete(offsets.map { dataFiles[$0] })
                            }
                    }
                } header: {
                    sectionHeader("Data") {
                        Button(role: .destructive) {
                            isDeletingData = true
                        } label: {
                            Label("Delete All Data", systemImage: "trash")
                        }
                        .disabled(dataFiles.isEmpty)
                    }
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .title) {
                    titleMenu
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .navigationDestination(item: $editing) { file in
                WorkflowFileEditor(file: file)
            }
            .quickLookPreview($previewing)
            .onAppear(perform: reload)
            .refreshable { reload() }
            .alert("Rename Workflow", isPresented: $isRenaming) {
                TextField("Name", text: $newName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Rename", action: rename)
            }
            .alert("New File", isPresented: $isCreatingFile) {
                TextField("File Name", text: $newFileName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Create", action: createFile)
            }
            .confirmationDialog("Delete All Data?", isPresented: $isDeletingData, titleVisibility: .visible) {
                Button("Delete All Data", role: .destructive, action: deleteData)
            } message: {
                Text("The workflow loses everything it saved.")
            }
            .alert($alert)
        }
    }

    private var titleMenu: some View {
        Menu {
            Section {
                Button {
                    newName = name
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .disabled(workflows.isRunning(name))
                Button {
                    isChoosingIcon = true
                } label: {
                    Label("Choose Icon", systemImage: "square.dashed")
                }
                Button(action: duplicate) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
            ShareLink(item: WorkflowFile(name: name), preview: SharePreview(name)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            HStack(spacing: 8) {
                WorkflowIconImage(icon: workflows.icons[name] ?? .default)
                Text(verbatim: name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text(verbatim: name))
        .popover(isPresented: $isChoosingIcon) {
            WorkflowIconPicker(icon: icon)
        }
    }

    private var icon: Binding<WorkflowIcon> {
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

    private func sectionHeader(_ title: LocalizedStringKey, @ViewBuilder action: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            action()
                .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private func fileRow(_ file: WorkflowFileItem) -> some View {
        if file.isText {
            NavigationLink {
                WorkflowFileEditor(file: file)
            } label: {
                Text(verbatim: file.name)
            }
        } else {
            Button {
                previewing = file.url
            } label: {
                Text(verbatim: file.name)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var sourceFolder: URL {
        WorkflowStore.url(of: name).appendingPathComponent(LibSwiptWorkflowSourceFolder, isDirectory: true)
    }

    private var dataFolder: URL {
        WorkflowStore.url(of: name).appendingPathComponent(LibSwiptWorkflowDataFolder, isDirectory: true)
    }

    private func reload() {
        sourceFiles = WorkflowFileItem.list(in: sourceFolder).sorted { first, second in
            if (first.name == LibSwiptWorkflowEntryFile) != (second.name == LibSwiptWorkflowEntryFile) {
                return first.name == LibSwiptWorkflowEntryFile
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
        dataFiles = WorkflowFileItem.list(in: dataFolder).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func rename() {
        guard newName.trimmingCharacters(in: .whitespacesAndNewlines) != name else { return }
        do {
            name = try workflows.rename(name, to: newName)
            reload()
        } catch {
            alert = AlertState(String(localized: "Can’t Rename the Workflow"), error: error)
        }
    }

    private func duplicate() {
        do {
            try workflows.duplicate(name)
        } catch {
            alert = AlertState(String(localized: "Can’t Duplicate the Workflow"), error: error)
        }
    }

    private func createFile() {
        let fileName = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard !fileName.isEmpty, !fileName.hasPrefix("."), !fileName.contains("/"), !fileName.contains("\0") else {
                throw MessageError(String(localized: "A file name can’t be empty, start with a period, or contain a slash."))
            }
            let url = sourceFolder.appendingPathComponent(fileName, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw MessageError(String(localized: "There’s already a file named “\(fileName)”."))
            }
            try Data().write(to: url, options: .withoutOverwriting)
            reload()
            editing = WorkflowFileItem(url: url, name: fileName)
        } catch {
            alert = AlertState(String(localized: "Can’t Create the File"), error: error)
        }
    }

    private func delete(_ files: [WorkflowFileItem]) {
        defer { reload() }
        do {
            for file in files {
                try FileManager.default.removeItem(at: file.url)
            }
        } catch {
            alert = AlertState(String(localized: "Can’t Delete the File"), error: error)
        }
    }

    private func deleteData() {
        defer { reload() }
        do {
            for entry in try FileManager.default.contentsOfDirectory(at: dataFolder, includingPropertiesForKeys: nil) {
                try FileManager.default.removeItem(at: entry)
            }
        } catch {
            alert = AlertState(String(localized: "Can’t Delete the Data"), error: error)
        }
    }
}

nonisolated struct WorkflowFileItem: Hashable, Identifiable, Sendable {
    let url: URL
    let name: String
    let isText: Bool

    var id: URL { url }

    init(url: URL, name: String) {
        self.url = url
        self.name = name
        if !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic {
            isText = type.conforms(to: .text)
        } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            isText = !data.contains(0) && String(data: data, encoding: .utf8) != nil
        } else {
            isText = false
        }
    }

    static func list(in folder: URL) -> [WorkflowFileItem] {
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else {
            return []
        }
        var files: [WorkflowFileItem] = []
        while let name = enumerator.nextObject() as? String {
            if (name as NSString).lastPathComponent.hasPrefix(".") {
                enumerator.skipDescendants()
            } else if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                files.append(WorkflowFileItem(url: folder.appendingPathComponent(name, isDirectory: false), name: name))
            }
        }
        return files
    }
}
