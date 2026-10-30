import ExpoModulesCore

@MainActor
public protocol SwiptHostDelegate: AnyObject {
  func call(swiplet: String, action: String, input: String) async throws -> String
  func setServiceEnabled(swiplet: String, enabled: Bool) async throws
  func surfaceDidMount(_ surface: String)
}

public final class SwiptHostModule: Module {
  @MainActor public static weak var delegate: SwiptHostDelegate?

  private static let lock = NSLock()
  private static let modules = NSHashTable<SwiptHostModule>.weakObjects()

  public static func send(_ event: String, _ body: [String: Any?]) {
    lock.lock()
    let modules = modules.allObjects
    lock.unlock()
    for module in modules {
      module.sendEvent(event, body)
    }
  }

  @MainActor
  private static func host() throws -> SwiptHostDelegate {
    guard let delegate else {
      throw Exception(name: "SwiptHostUnavailable", description: "Swipt isn't ready for swiplets")
    }
    return delegate
  }

  public func definition() -> ModuleDefinition {
    Name("SwiptHost")

    Events("service")

    OnCreate {
      Self.lock.lock()
      Self.modules.add(self)
      Self.lock.unlock()
    }

    OnDestroy {
      Self.lock.lock()
      Self.modules.remove(self)
      Self.lock.unlock()
    }

    AsyncFunction("call") { @MainActor (swiplet: String, action: String, input: String) async throws -> String in
      try await Self.host().call(swiplet: swiplet, action: action, input: input)
    }

    AsyncFunction("setServiceEnabled") { @MainActor (swiplet: String, enabled: Bool) async throws in
      try await Self.host().setServiceEnabled(swiplet: swiplet, enabled: enabled)
    }

    Function("mounted") { (surface: String) in
      Task { @MainActor in
        Self.delegate?.surfaceDidMount(surface)
      }
    }
  }
}
