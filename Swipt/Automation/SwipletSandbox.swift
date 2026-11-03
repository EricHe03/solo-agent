internal import ExpoModulesCore
import Foundation
import React
import Synchronization

// Swiplet interfaces call every native module their runtime links. These keep the ones that reach
// files to the swiplet's own directories, and the ones that reach state shared by the whole app to
// the swiplet's runtime; `@swipt/api/file-system` is how swiplets get to files.

nonisolated struct SwipletFiles: Sendable {
    private let roots: [String]

    init(roots: [URL]) {
        self.roots = roots.map(Self.resolved)
    }

    func contains(_ url: URL) -> Bool {
        let path = Self.resolved(url)
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// React Native's networking module, behind `<Image>`, reads any `file:` URL.
nonisolated final class SwipletFileRequestHandler: RCTFileRequestHandler {
    private let files: SwipletFiles

    init(files: SwipletFiles) {
        self.files = files
        super.init()
    }

    override func canHandle(_ request: URLRequest) -> Bool {
        guard super.canHandle(request), let url = request.url else { return false }
        return files.contains(url)
    }
}

nonisolated final class SwipletNetworking: RCTNetworking {
    static func make(files: SwipletFiles) -> SwipletNetworking {
        SwipletNetworking { registry in
            let handlers: [RCTURLRequestHandler?] = [
                RCTDataRequestHandler(), SwipletFileRequestHandler(files: files), registry?.module(forName: "BlobModule") as? RCTURLRequestHandler,
            ]
            return handlers.compactMap { $0 }
        }
    }
}

/// React Native's share sheet hands a `file:` URL to the activities as the file itself.
nonisolated final class SwipletActionSheetManager: RCTActionSheetManager {
    private typealias Callback = @convention(block) (NSArray?) -> Void

    private static let restricted: Void = {
        let selector = NSSelectorFromString("showShareActionSheetWithOptions:failureCallback:successCallback:")
        guard let method = class_getInstanceMethod(RCTActionSheetManager.self, selector) else { return }
        typealias Share = @convention(c) (AnyObject, Selector, UnsafeRawPointer, Callback, Callback) -> Void
        let share = unsafeBitCast(method_getImplementation(method), to: Share.self)
        // The options are a JS::NativeActionSheetManager::SpecShowShareActionSheetWithOptionsOptions,
        // whose only field is the dictionary JavaScript passed.
        let restricted: @convention(block) (SwipletActionSheetManager, UnsafeRawPointer, Callback, Callback) -> Void = { manager, options, failure, success in
            let url = RCTConvert.nsurl(RCTConvert.nsString(options.load(as: NSDictionary.self)["url"])) as URL?
            if let url, url.isFileURL, !manager.files.contains(url) {
                failure([RCTMakeError("swiplets share files from their own directories", nil, nil)])
                return
            }
            share(manager, selector, options, failure, success)
        }
        class_addMethod(SwipletActionSheetManager.self, selector, imp_implementationWithBlock(restricted), method_getTypeEncoding(method))
    }()

    private let files: SwipletFiles

    init(files: SwipletFiles) {
        _ = Self.restricted
        self.files = files
        super.init()
    }
}

/// Takes the place of expo-asset's module, whose `downloadAsync` saves a download under a name the
/// caller picks, which can lead anywhere in Swipt's container. Swiplet assets are file URLs already.
nonisolated final class SwipletAssetModule: Module {
    func definition() -> ModuleDefinition {
        Name("ExpoAsset")

        AsyncFunction("downloadAsync") { (url: URL, _: String?, _: String) throws -> String in
            guard url.isFileURL else {
                throw Exception(name: "ERR_ASSET_DOWNLOAD", description: "swiplets load assets from file URLs")
            }
            return url.standardizedFileURL.absoluteString
        }
    }
}

/// Takes the place of expo-keep-awake's module, which sets the idle timer Swipt itself manages and
/// leaves it set once the runtime is gone.
nonisolated final class SwipletKeepAwakeModule: Module {
    private let tags = Mutex<Set<String>>([])

    func definition() -> ModuleDefinition {
        Name("ExpoKeepAwake")

        AsyncFunction("activate") { (tag: String) -> Bool in
            self.update { _ = $0.insert(tag) }
            return true
        }

        AsyncFunction("deactivate") { (tag: String) -> Bool in
            self.update { _ = $0.remove(tag) }
            return true
        }

        AsyncFunction("isActivated") { () -> Bool in
            self.tags.withLock { !$0.isEmpty }
        }

        OnDestroy {
            self.update { $0.removeAll() }
        }
    }

    private func update(_ change: (inout Set<String>) -> Void) {
        let holder = ObjectIdentifier(self)
        let awake = tags.withLock { tags in
            change(&tags)
            return !tags.isEmpty
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Platform.shared.keepAwake(holder, awake)
            }
        }
    }
}

nonisolated enum SwipletSandbox {
    /// DevTools reloads through it, and so does `DevSettings.reload()` via RCTTriggerReloadCommandListeners,
    /// which calls it on every RCTHost in the process.
    static func ignoreReloads() {
        guard let host = NSClassFromString("RCTHost"), let method = class_getInstanceMethod(host, NSSelectorFromString("didReceiveReloadCommand")) else { return }
        let ignore: @convention(block) (AnyObject) -> Void = { _ in }
        method_setImplementation(method, imp_implementationWithBlock(ignore))
    }

    /// Runs before the app context registers the linked modules, which can't replace these then.
    static func replaceModules(in appContext: AppContext) {
        for module in [SwipletAssetModule.self, SwipletKeepAwakeModule.self] as [AnyModule.Type] {
            appContext.moduleRegistry.register(moduleType: module, name: nil, preventModuleOverriding: true)
        }
    }
}
