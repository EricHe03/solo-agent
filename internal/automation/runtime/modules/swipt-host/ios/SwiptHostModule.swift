import ExpoModulesCore

public struct SwiptHostFileInfo {
  public var exists = false
  public var directory = false
  public var size: Int64 = 0
  public var modified: Int64 = 0

  public init() {}

  public init(exists: Bool, directory: Bool, size: Int64, modified: Int64) {
    self.exists = exists
    self.directory = directory
    self.size = size
    self.modified = modified
  }
}

public struct SwiptHostFileEntry {
  public let name: String
  public let directory: Bool

  public init(name: String, directory: Bool) {
    self.name = name
    self.directory = directory
  }
}

@MainActor
public protocol SwiptHostDelegate: AnyObject {
  func call(swiplet: String, action: String, input: String) async throws -> String
  func setServiceEnabled(swiplet: String, enabled: Bool) async throws
  func surfaceDidMount(_ surface: String)
  func statFile(swiplet: String, root: String, path: String) async throws -> SwiptHostFileInfo
  func listFiles(swiplet: String, root: String, path: String) async throws -> [SwiptHostFileEntry]
  func readFile(swiplet: String, root: String, path: String) async throws -> Data
  func writeFile(swiplet: String, root: String, path: String, data: Data) async throws
  func makeDirectory(swiplet: String, root: String, path: String) async throws
  func removeFile(swiplet: String, root: String, path: String) async throws
  func copyFile(swiplet: String, root: String, from: String, toRoot: String, to: String) async throws
  func moveFile(swiplet: String, root: String, from: String, toRoot: String, to: String) async throws
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

    AsyncFunction("fileStat") { @MainActor (swiplet: String, root: String, path: String) async throws -> [String: Any] in
      let info = try await Self.host().statFile(swiplet: swiplet, root: root, path: path)
      return ["exists": info.exists, "directory": info.directory, "size": info.size, "modified": info.modified]
    }

    AsyncFunction("fileList") { @MainActor (swiplet: String, root: String, path: String) async throws -> [[String: Any]] in
      try await Self.host().listFiles(swiplet: swiplet, root: root, path: path).map { ["name": $0.name, "directory": $0.directory] }
    }

    AsyncFunction("fileRead") { @MainActor (swiplet: String, root: String, path: String) async throws -> String in
      try await Self.host().readFile(swiplet: swiplet, root: root, path: path).base64EncodedString()
    }

    AsyncFunction("fileReadText") { @MainActor (swiplet: String, root: String, path: String) async throws -> String in
      String(decoding: try await Self.host().readFile(swiplet: swiplet, root: root, path: path), as: UTF8.self)
    }

    AsyncFunction("fileWrite") { @MainActor (swiplet: String, root: String, path: String, base64: String) async throws in
      guard let data = Data(base64Encoded: base64) else {
        throw Exception(name: "SwiptHostInvalidData", description: "the data is not base64")
      }
      try await Self.host().writeFile(swiplet: swiplet, root: root, path: path, data: data)
    }

    AsyncFunction("fileWriteText") { @MainActor (swiplet: String, root: String, path: String, text: String) async throws in
      try await Self.host().writeFile(swiplet: swiplet, root: root, path: path, data: Data(text.utf8))
    }

    AsyncFunction("fileMkdir") { @MainActor (swiplet: String, root: String, path: String) async throws in
      try await Self.host().makeDirectory(swiplet: swiplet, root: root, path: path)
    }

    AsyncFunction("fileRemove") { @MainActor (swiplet: String, root: String, path: String) async throws in
      try await Self.host().removeFile(swiplet: swiplet, root: root, path: path)
    }

    AsyncFunction("fileCopy") { @MainActor (swiplet: String, root: String, from: String, toRoot: String, to: String) async throws in
      try await Self.host().copyFile(swiplet: swiplet, root: root, from: from, toRoot: toRoot, to: to)
    }

    AsyncFunction("fileMove") { @MainActor (swiplet: String, root: String, from: String, toRoot: String, to: String) async throws in
      try await Self.host().moveFile(swiplet: swiplet, root: root, from: from, toRoot: toRoot, to: to)
    }
  }
}
