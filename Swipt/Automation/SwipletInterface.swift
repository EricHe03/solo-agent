internal import Expo
import LibSwipt
import Perception
import React
import ReactAppDependencyProvider
import SwiftUI
internal import SwiptHost

@available(iOS 27, *)
struct SwipletInterface: View {
    let name: String
    let entry: SwipletEntry

    private let swiplets = SwipletStore.shared

    var body: some View {
        WithPerceptionTracking {
            SwipletSurfaceView(name: name, entry: swiplets.interfaces[name] ?? entry)
                .ignoresSafeArea()
        }
    }
}

@available(iOS 27, *)
private struct SwipletSurfaceView: UIViewControllerRepresentable {
    let name: String
    let entry: SwipletEntry

    func makeUIViewController(context: Context) -> SwipletViewController {
        SwipletViewController(name: name, entry: entry)
    }

    func updateUIViewController(_ controller: SwipletViewController, context: Context) {
        controller.show(entry)
    }

    static func dismantleUIViewController(_ controller: SwipletViewController, coordinator: ()) {
        controller.stop()
    }
}

@available(iOS 27, *)
private final class SwipletViewController: UIViewController {
    private let name: String
    private var displayed: SwipletSurface
    private var loading: SwipletSurface?

    init(name: String, entry: SwipletEntry) {
        self.name = name
        displayed = SwipletHost.shared.take(name, entry: entry)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        attach(displayed)
    }

    func stop() {
        displayed.stop()
        loading?.stop()
    }

    private func attach(_ surface: SwipletSurface) {
        surface.view.frame = view.bounds
        surface.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(surface.view)
        surface.whenFailed { [name] message in
            let title = SwipletStore.shared.titles[name] ?? name
            ErrorAlert.shared.report(AlertState(String(localized: "Couldn’t Open “\(title)”"), errorMessage: message) {
                SwipletHost.shared.exit(swiplet: name)
            })
        }
    }

    func show(_ entry: SwipletEntry) {
        guard entry != (loading ?? displayed).entry else { return }
        loading?.stop()
        let next = SwipletHost.shared.makeSurface(name, entry: entry)
        loading = next
        next.whenMounted { [weak self, weak next] in
            guard let self, let next, loading === next else { return }
            loading = nil
            attach(next)
            displayed.view.removeFromSuperview()
            displayed.stop()
            displayed = next
        }
    }
}

@available(iOS 27, *)
final class SwipletSurface {
    let entry: SwipletEntry
    let view: RCTSurfaceHostingProxyRootView
    private var mounted = false
    private var pending: [() -> Void] = []
    private var failure: String?
    private var onFailure: ((String) -> Void)?

    fileprivate init(entry: SwipletEntry, view: RCTSurfaceHostingProxyRootView) {
        self.entry = entry
        self.view = view
    }

    func whenMounted(_ action: @escaping () -> Void) {
        if mounted {
            action()
        } else {
            pending.append(action)
        }
    }

    fileprivate func didMount() {
        mounted = true
        let actions = pending
        pending = []
        actions.forEach { $0() }
    }

    func whenFailed(_ action: @escaping (String) -> Void) {
        if let failure {
            action(failure)
        } else {
            onFailure = action
        }
    }

    fileprivate func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        onFailure?(message)
    }

    func stop() {
        view.surface.stop()
    }
}

@available(iOS 27, *)
final class SwipletHost: SwiptHostDelegate {
    static let shared = SwipletHost()

    private final class FactoryDelegate: ExpoReactNativeFactoryDelegate {
        override func bundleURL() -> URL? {
            Bundle.main.url(forResource: "main", withExtension: "jsbundle")
        }
    }

    private let delegate = FactoryDelegate()
    private let factory: ExpoReactNativeFactory
    private var prepared: [String: SwipletSurface] = [:]
    private var presented: [(name: String, exit: () -> Void)] = []
    private let surfaces = NSMapTable<NSString, SwipletSurface>.strongToWeakObjects()

    private init() {
        delegate.dependencyProvider = RCTAppDependencyProvider()
        factory = ExpoReactNativeFactory(delegate: delegate)
        SwiptHostModule.delegate = self
        factory.rootViewFactory.initializeReactHost(
            launchOptions: nil, bundleConfiguration: factory.bundleConfiguration, devMenuConfiguration: .default())
    }

    func prepare(_ interfaces: [String: SwipletEntry]) {
        for (name, surface) in prepared where interfaces[name] == nil {
            surface.stop()
            prepared[name] = nil
        }
        for (name, entry) in interfaces {
            if prepared[name]?.entry == entry {
                continue
            }
            prepared[name]?.stop()
            prepared[name] = makeSurface(name, entry: entry)
        }
    }

    func take(_ name: String, entry: SwipletEntry) -> SwipletSurface {
        if let surface = prepared.removeValue(forKey: name) {
            if surface.entry == entry {
                return surface
            }
            surface.stop()
        }
        return makeSurface(name, entry: entry)
    }

    func makeSurface(_ name: String, entry: SwipletEntry) -> SwipletSurface {
        let service = SwipletStore.shared.service(of: name)
        let id = UUID().uuidString
        let view = factory.rootViewFactory.view(
            withModuleName: "main",
            initialProperties: [
                "surface": id,
                "name": name,
                "file": entry.url.lastPathComponent,
                "source": (try? String(contentsOf: entry.url, encoding: .utf8)) ?? "",
                "dataDirectory": SwipletStore.shared.dataDirectory(of: name)?.absoluteString ?? "",
                "assetsDirectory": SwipletStore.shared.assetsDirectory(of: name)?.absoluteString ?? "",
                "service": [
                    "enabled": service.enabled, "status": service.status.rawValue, "error": service.error,
                    "since": service.since.map { $0.timeIntervalSince1970 * 1000 } ?? 0,
                ] as [String: Any],
            ]
        ) as! RCTSurfaceHostingProxyRootView
        let windowBounds = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds }.first
        view.frame = windowBounds ?? .zero
        view.layoutIfNeeded()
        let surface = SwipletSurface(entry: entry, view: view)
        surfaces.setObject(surface, forKey: id as NSString)
        return surface
    }

    func call(swiplet: String, action: String, input: String) async throws -> String {
        try await Platform.shared.callAction(swiplet, action: action, input: input, caller: LibSwiptCallerApp, dialogs: .app)
    }

    func setServiceEnabled(swiplet: String, enabled: Bool) async throws {
        try await SwipletStore.shared.setServiceEnabled(swiplet, enabled)
    }

    func statFile(swiplet: String, root: String, path: String) async throws -> SwiptHostFileInfo {
        let info = try await Platform.shared.statSwipletFile(swiplet, root: root, path: path)
        return SwiptHostFileInfo(exists: info.exists, directory: info.directory, size: info.size, modified: info.modified)
    }

    func listFiles(swiplet: String, root: String, path: String) async throws -> [SwiptHostFileEntry] {
        try await Platform.shared.listSwipletFiles(swiplet, root: root, path: path).map { SwiptHostFileEntry(name: $0.name, directory: $0.directory) }
    }

    func readFile(swiplet: String, root: String, path: String) async throws -> Data {
        try await Platform.shared.readSwipletFile(swiplet, root: root, path: path)
    }

    func writeFile(swiplet: String, root: String, path: String, data: Data) async throws {
        try await Platform.shared.writeSwipletFile(swiplet, root: root, path: path, data: data)
    }

    func makeDirectory(swiplet: String, root: String, path: String) async throws {
        try await Platform.shared.makeSwipletDirectory(swiplet, root: root, path: path)
    }

    func removeFile(swiplet: String, root: String, path: String) async throws {
        try await Platform.shared.removeSwipletFile(swiplet, root: root, path: path)
    }

    func copyFile(swiplet: String, root: String, from: String, toRoot: String, to: String) async throws {
        try await Platform.shared.copySwipletFile(swiplet, root: root, from: from, toRoot: toRoot, to: to)
    }

    func moveFile(swiplet: String, root: String, from: String, toRoot: String, to: String) async throws {
        try await Platform.shared.moveSwipletFile(swiplet, root: root, from: from, toRoot: toRoot, to: to)
    }

    func didPresent(_ name: String, exit: @escaping () -> Void) {
        presented.removeAll { $0.name == name }
        presented.append((name, exit))
    }

    func didDismiss(_ name: String) {
        presented.removeAll { $0.name == name }
    }

    func exit(swiplet: String) {
        presented.last { $0.name == swiplet }?.exit()
    }

    func log(swiplet: String, level: String, message: String) {
        let level = switch level {
        case "error": LibSwiptLogLevelError
        case "warn": LibSwiptLogLevelWarn
        case "debug": LibSwiptLogLevelDebug
        default: LibSwiptLogLevelInfo
        }
        Platform.shared.logSwiplet(swiplet, level: level, message: message)
    }

    func fail(surface: String, message: String) {
        surfaces.object(forKey: surface as NSString)?.fail(message)
    }

    func report(swiplet: String, message: String) {
        let name = swiplet.isEmpty ? presented.last?.name : swiplet
        let title = name.map { String(localized: "“\(SwipletStore.shared.titles[$0] ?? $0)” Error") } ?? String(localized: "Swiplet Error")
        ErrorAlert.shared.report(AlertState(title, errorMessage: message))
    }

    func surfaceDidMount(_ surface: String) {
        surfaces.object(forKey: surface as NSString)?.didMount()
    }
}
