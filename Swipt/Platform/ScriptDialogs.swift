import Contacts
import ContactsUI
import MapKit
import Perception
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@available(iOS 27, *)
@Perceptible
final class ScriptDialogs {
    static let shared = ScriptDialogs()

    struct Presentation: Identifiable {
        let id: UUID
        let request: DialogRequest
        fileprivate let continuation: CheckedContinuation<DialogAnswer, any Error>
    }

    private(set) var presentations: [Presentation] = []
    @PerceptionIgnored private var backdrop: UIImage?
    @PerceptionIgnored private var window: UIWindow?

    private init() {
        NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.update() }
        }
        NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.showBackdrop(nil) }
        }
    }

    func showBackdrop(_ image: Data?) {
        backdrop = image.flatMap(UIImage.init(data:))
        update()
        if backdrop != nil, let scene = window?.windowScene, scene.activationState == .background {
            window?.layoutIfNeeded()
            UIApplication.shared.requestSceneSessionRefresh(scene.session)
        }
    }

    func present(_ request: DialogRequest) async throws -> DialogAnswer {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                presentations.append(Presentation(id: id, request: request, continuation: continuation))
                update()
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
    }

    func answer(_ presentation: Presentation, with answer: DialogAnswer) {
        finish(presentation.id, with: .success(answer))
    }

    func dismiss(_ presentation: Presentation) {
        finish(presentation.id, with: .failure(CancellationError()))
    }

    private func finish(_ id: UUID, with result: Result<DialogAnswer, any Error>) {
        guard let index = presentations.firstIndex(where: { $0.id == id }) else { return }
        presentations.remove(at: index).continuation.resume(with: result)
        update()
    }

    private func update() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
        if active != nil, let first = presentations.first, case .foreground = first.request {
            backdrop = nil
            finish(first.id, with: .success(.none))
            return
        }
        guard !presentations.isEmpty || backdrop != nil, let scene = active ?? scenes.first else {
            window?.isHidden = true
            window = nil
            return
        }
        if window?.windowScene !== scene {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert
            window.rootViewController = OverlayController()
            window.makeKeyAndVisible()
            self.window = window
        }
        (window?.rootViewController as? OverlayController)?.backdrop = backdrop
    }
}

// Shortcuts labels its dialogs from these tables (iOS 27.2 24B115): the confirmation verbs and Cancel from AppIntents,
// Done, Text, URL and Search from WorkflowUI, Yes and No from WorkflowUICore.
private enum SystemText {
    static func appIntents(_ key: String) -> String {
        lookup("/System/Library/Frameworks/AppIntents.framework", key)
    }

    static func workflowUI(_ key: String) -> String {
        lookup("/System/Library/PrivateFrameworks/WorkflowUI.framework", key)
    }

    static func workflowUICore(_ key: String) -> String {
        lookup("/System/Library/PrivateFrameworks/WorkflowUICore.framework", key)
    }

    private static func lookup(_ path: String, _ key: String) -> String {
        Bundle(path: path)?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

private enum Metrics {
    static let width: CGFloat = 424
    static let cornerRadius: CGFloat = 28
    static let inset: CGFloat = 15
    static let spacing: CGFloat = 12.5
    static let buttonHeight: CGFloat = 53.5
    static let rowHeight: CGFloat = 54
}

@available(iOS 27, *)
private final class OverlayController: UIViewController {
    private let backdropView = UIImageView()
    private let host = UIHostingController(rootView: DialogOverlay())

    var backdrop: UIImage? {
        didSet {
            backdropView.image = backdrop
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    override var prefersStatusBarHidden: Bool {
        backdrop != nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdropView.frame = view.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdropView)
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

@available(iOS 27, *)
private struct DialogOverlay: View {
    private let dialogs = ScriptDialogs.shared

    var body: some View {
        WithPerceptionTracking {
            ZStack(alignment: .top) {
                Color.clear
                if let presentation = dialogs.presentations.first {
                    DialogPlatter(presentation: presentation)
                        .id(presentation.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.15), value: dialogs.presentations.first?.id)
        }
    }
}

@available(iOS 27, *)
private struct DialogPlatter: View {
    let presentation: ScriptDialogs.Presentation
    @State private var drag: CGFloat = 0

    var body: some View {
        content
            .frame(maxWidth: Metrics.width)
            .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cornerRadius))
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .offset(y: drag < 0 ? drag : sqrt(drag) * 3)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height < -60 || value.predictedEndTranslation.height < -160 {
                            ScriptDialogs.shared.dismiss(presentation)
                        } else {
                            withAnimation(.spring(duration: 0.3)) { drag = 0 }
                        }
                    })
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.request {
        case .choice(let prompt, let options):
            let order = options.indices.filter { options[$0].style == .cancel } + options.indices.filter { options[$0].style != .cancel }
            DialogLayout(prompt: prompt, separated: true) {
                VStack(spacing: Metrics.spacing) {
                    ForEach(order, id: \.self) { index in
                        let option = options[index]
                        let role: DialogButton.Role =
                            switch option.style {
                            case .default: .prominent
                            case .destructive: .destructive
                            case .cancel: .neutral
                            }
                        DialogButton(title: option.title, role: role, bold: option.style != .cancel) { answer(.index(index)) }
                    }
                }
            }
        case .confirmation(let prompt, let action):
            let (accept, deny, destructive) =
                switch action {
                case .named(let name): (SystemText.appIntents(name.title), SystemText.appIntents("Cancel"), false)
                case .custom(let accept, let deny, let destructive): (accept, deny, destructive)
                }
            DialogLayout(prompt: prompt, separated: true) {
                HStack(spacing: Metrics.spacing) {
                    DialogButton(title: deny, role: .neutral) { dismiss() }
                    DialogButton(title: accept, role: destructive ? .destructive : .prominent) { answer(.none) }
                }
            }
        case .valueConfirmation(let prompt, _):
            DialogLayout(prompt: prompt, separated: true) {
                HStack(spacing: Metrics.spacing) {
                    DialogButton(title: SystemText.workflowUICore("No"), role: .neutral) { answer(.confirmed(false)) }
                    DialogButton(title: SystemText.workflowUICore("Yes"), role: .prominent) { answer(.confirmed(true)) }
                }
            }
        case .disambiguation(let prompt, let values):
            DialogLayout(prompt: prompt, separated: false) {
                DialogList(rows: values.indices.map { (id: $0, title: values[$0], subtitle: nil) }) { answer(.index($0)) }
            }
        case .value(let prompt, let field):
            ValueDialog(prompt: prompt, field: field, answer: answer, dismiss: dismiss)
        case .foreground:
            EmptyView()
        }
    }

    private func answer(_ answer: DialogAnswer) {
        ScriptDialogs.shared.answer(presentation, with: answer)
    }

    private func dismiss() {
        ScriptDialogs.shared.dismiss(presentation)
    }
}

private extension DialogRequest.ActionName {
    var title: String {
        rawValue.reduce(into: "") { title, character in
            if title.isEmpty {
                title.append(character.uppercased())
            } else {
                if character.isUppercase { title.append(" ") }
                title.append(character)
            }
        }
    }
}

private struct DialogLayout<Content: View>: View {
    let prompt: String?
    let separated: Bool
    @ViewBuilder let content: Content
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            if let prompt {
                Text(verbatim: prompt)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 15.5)
                if separated {
                    Rectangle()
                        .fill(.white.opacity(0.17))
                        .frame(height: 1 / displayScale)
                }
            }
            content
                .padding(.horizontal, Metrics.inset)
                .padding(.top, prompt == nil ? 14.5 : separated ? 15.5 : 0)
                .padding(.bottom, Metrics.inset)
        }
    }
}

@available(iOS 27, *)
private struct DialogButton: View {
    enum Role {
        case neutral
        case prominent
        case destructive
    }

    let title: String
    let role: Role
    var bold = true
    let action: () -> Void

    var body: some View {
        let label = Text(verbatim: title)
            .font(bold ? .headline : .body)
            .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight - 14)
        if role == .neutral {
            Button(action: action) { label }
                .buttonStyle(.glass)
        } else {
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .tint(role == .destructive ? .red : .blue)
        }
    }
}

@available(iOS 27, *)
private struct DialogList: View {
    let rows: [(id: Int, title: String, subtitle: String?)]
    let choose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { position, row in
                if position > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(height: 0.5)
                        .padding(.leading, 24)
                        .padding(.trailing, 10)
                }
                Button {
                    choose(row.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.title)
                            .font(.body)
                        if let subtitle = row.subtitle {
                            Text(verbatim: subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                    .padding(.horizontal, 24)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

@available(iOS 27, *)
private struct ValueDialog: View {
    let prompt: String?
    let field: DialogRequest.Field
    let answer: (DialogAnswer) -> Void
    let dismiss: () -> Void

    @State private var text = ""
    @State private var count = 0
    @State private var date = Date.now

    var body: some View {
        switch field {
        case .text(let multiline, let literal):
            input(separated: false) {
                InputField(text: $text, kind: .text(multiline: multiline, literal: literal), placeholder: SystemText.workflowUI("Text")) { submitText() }
                    .frame(height: multiline ? 114 : Metrics.buttonHeight)
                    .glassEffect(.regular, in: multiline ? AnyShape(.rect(cornerRadius: 24)) : AnyShape(.capsule))
            } done: {
                submitText()
            }
        case .integer(let stepper, let min, let max):
            if stepper {
                input(separated: false) {
                    HStack {
                        StepButton(symbol: "minus", enabled: count > (min ?? .min)) { count -= 1 }
                        Text(count, format: .number)
                            .font(.system(size: 34, weight: .semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                        StepButton(symbol: "plus", enabled: count < (max ?? .max)) { count += 1 }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 86)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .onAppear { count = Swift.min(Swift.max(0, min ?? .min), max ?? .max) }
                } done: {
                    answer(.number(Double(count)))
                }
            } else {
                numberInput(integer: true, min: min.map(Double.init), max: max.map(Double.init))
            }
        case .number(let min, let max):
            numberInput(integer: false, min: min, max: max)
        case .date:
            input(separated: true) {
                DatePicker(selection: $date, displayedComponents: .date) { EmptyView() }
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            } done: {
                answer(.date(date))
            }
        case .time:
            input(separated: true) {
                DatePicker(selection: $date, displayedComponents: .hourAndMinute) { EmptyView() }
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            } done: {
                answer(.date(date))
            }
        case .dateTime:
            input(separated: true) {
                DatePicker(selection: $date, displayedComponents: [.date, .hourAndMinute]) { EmptyView() }
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            } done: {
                answer(.date(date))
            }
        case .file:
            FilePicker(answer: answer, dismiss: dismiss)
        case .person:
            ContactPicker(answer: answer, dismiss: dismiss)
        case .placemark:
            PlacemarkSearch(prompt: prompt, answer: answer)
        }
    }

    private func input(separated: Bool, @ViewBuilder content: () -> some View, done: @escaping () -> Void) -> some View {
        DialogLayout(prompt: prompt, separated: separated) {
            VStack(spacing: Metrics.spacing) {
                content()
                HStack(spacing: Metrics.spacing) {
                    DialogButton(title: SystemText.workflowUI("Cancel"), role: .neutral, action: dismiss)
                    DialogButton(title: SystemText.workflowUI("Done"), role: .prominent, action: done)
                }
            }
        }
    }

    private func numberInput(integer: Bool, min: Double?, max: Double?) -> some View {
        let value = Double(text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
        let fits = value.map { $0 >= min ?? -.infinity && $0 <= max ?? .infinity } ?? false
        return input(separated: false) {
            VStack(spacing: 8) {
                InputField(text: $text, kind: .number(integer: integer, negative: min.map { $0 < 0 } ?? true), placeholder: "0") {
                    if fits, let value { answer(.number(value)) }
                }
                .frame(height: 86)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                if !text.isEmpty, !fits, min != nil || max != nil {
                    Text(verbatim: DialogRequest.rangeHint(min: min, max: max))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } done: {
            if fits, let value { answer(.number(value)) }
        }
    }

    private func submitText() {
        answer(.text(text))
    }
}

@available(iOS 27, *)
private struct StepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

@available(iOS 27, *)
private struct InputField: UIViewRepresentable {
    enum Kind: Equatable {
        case text(multiline: Bool, literal: Bool)
        case number(integer: Bool, negative: Bool)
    }

    @Binding var text: String
    let kind: Kind
    let placeholder: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let input: UIView & UITextInput
        switch kind {
        case .text(true, let literal):
            let view = PlaceholderTextView()
            view.placeholder.text = placeholder
            view.font = .preferredFont(forTextStyle: .body)
            view.backgroundColor = .clear
            view.textContainerInset = UIEdgeInsets(top: 15, left: 12, bottom: 15, right: 12)
            view.delegate = context.coordinator
            if literal {
                view.autocapitalizationType = .none
                view.autocorrectionType = .no
                view.spellCheckingType = .no
                view.smartQuotesType = .no
                view.smartDashesType = .no
                view.smartInsertDeleteType = .no
            }
            input = view
        case .text(false, let literal):
            let field = UITextField()
            field.placeholder = placeholder
            field.font = .preferredFont(forTextStyle: .body)
            field.returnKeyType = .done
            field.delegate = context.coordinator
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            if literal {
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.spellCheckingType = .no
                field.smartQuotesType = .no
                field.smartDashesType = .no
                field.smartInsertDeleteType = .no
            }
            input = field
        case .number(let integer, let negative):
            let field = UITextField()
            field.placeholder = placeholder
            field.font = .systemFont(ofSize: 34, weight: .semibold)
            field.textAlignment = .center
            field.keyboardType = integer ? .numberPad : .decimalPad
            field.delegate = context.coordinator
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            if negative {
                field.inputAccessoryView = context.coordinator.signAccessory(for: field)
            }
            input = field
        }
        let container = UIView()
        input.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(input)
        let horizontal: CGFloat = if case .text(true, _) = kind { 4 } else { 20 }
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            input.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            input.topAnchor.constraint(equalTo: container.topAnchor),
            input.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { input.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UITextFieldDelegate, UITextViewDelegate {
        var parent: InputField

        init(_ parent: InputField) {
            self.parent = parent
        }

        @objc func changed(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            (view as? PlaceholderTextView)?.placeholder.isHidden = !view.text.isEmpty
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            parent.submit()
            return false
        }

        func signAccessory(for field: UITextField) -> UIView {
            var configuration = UIButton.Configuration.glass()
            configuration.image = UIImage(systemName: "plus.forwardslash.minus")
            configuration.cornerStyle = .capsule
            let button = UIButton(
                configuration: configuration,
                primaryAction: UIAction { [weak self, weak field] _ in
                    guard let self, let field else { return }
                    let current = field.text ?? ""
                    field.text = current.hasPrefix("-") ? String(current.dropFirst()) : "-" + current
                    self.changed(field)
                })
            button.translatesAutoresizingMaskIntoConstraints = false
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 60))
            bar.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 135),
                button.heightAnchor.constraint(equalToConstant: 48),
            ])
            return bar
        }
    }
}

private final class PlaceholderTextView: UITextView {
    let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.textColor = .placeholderText
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 15),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@available(iOS 27, *)
private struct FilePicker: View {
    let answer: (DialogAnswer) -> Void
    let dismiss: () -> Void
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .frame(height: 0)
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else {
                    dismiss()
                    return
                }
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                guard let data = try? Data(contentsOf: url) else {
                    dismiss()
                    return
                }
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
                answer(.file(name: url.lastPathComponent, type: type?.identifier ?? "", data: data))
            } onCancellation: {
                dismiss()
            }
    }
}

private struct ContactPicker: UIViewControllerRepresentable {
    let answer: (DialogAnswer) -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        DispatchQueue.main.async {
            let picker = CNContactPickerViewController()
            picker.delegate = context.coordinator
            host.present(picker, animated: true)
        }
        return host
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPicker

        init(_ parent: ContactPicker) {
            self.parent = parent
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            let handle: (type: String, value: String)? =
                if let phone = contact.phoneNumbers.first {
                    ("phoneNumber", phone.value.stringValue)
                } else if let email = contact.emailAddresses.first {
                    ("emailAddress", email.value as String)
                } else {
                    nil
                }
            parent.answer(.person(name: name, handle: handle))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.dismiss()
        }
    }
}

@available(iOS 27, *)
private struct PlacemarkSearch: View {
    let prompt: String?
    let answer: (DialogAnswer) -> Void
    @State private var query = ""
    @State private var completer = PlacemarkCompleter()

    var body: some View {
        WithPerceptionTracking {
            DialogLayout(prompt: prompt, separated: false) {
                VStack(spacing: Metrics.spacing) {
                    InputField(text: $query, kind: .text(multiline: false, literal: false), placeholder: SystemText.workflowUI("Search")) {}
                        .frame(height: Metrics.buttonHeight)
                        .glassEffect(.regular, in: .capsule)
                    if !completer.results.isEmpty {
                        DialogList(rows: completer.results.prefix(6).enumerated().map { (id: $0.offset, title: $0.element.title, subtitle: $0.element.subtitle) }) {
                            choose(completer.results[$0])
                        }
                    }
                }
            }
            .onChange(of: query) { completer.search(query) }
        }
    }

    private func choose(_ completion: MKLocalSearchCompletion) {
        Task {
            let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
            answer(.placemark(name: item?.name ?? completion.title, coordinate: item?.location.coordinate, address: item?.address?.fullAddress))
        }
    }
}

@Perceptible
private final class PlacemarkCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []
    @PerceptionIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
    }

    func search(_ query: String) {
        if query.isEmpty {
            results = []
        } else {
            completer.queryFragment = query
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }
}
