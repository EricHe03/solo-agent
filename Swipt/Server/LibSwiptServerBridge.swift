import Foundation
import LibSwipt

nonisolated struct DeviceServerStateChange: Sendable {
    var state: Int32
    var errorCode: Int32
    var message: String
}

nonisolated final class DeviceServerEvents: NSObject, LibSwiptDeviceServerHandlerProtocol, @unchecked Sendable {
    private let deliver: @Sendable (DeviceServerStateChange) -> Void
    private let deliverDialog: @Sendable (_ dialogID: Int64, _ request: String?) -> Void
    private let deliverBackdrop: @Sendable (Data?) -> Void

    init(
        state deliver: @escaping @Sendable (DeviceServerStateChange) -> Void,
        dialog deliverDialog: @escaping @Sendable (_ dialogID: Int64, _ request: String?) -> Void,
        backdrop deliverBackdrop: @escaping @Sendable (Data?) -> Void
    ) {
        self.deliver = deliver
        self.deliverDialog = deliverDialog
        self.deliverBackdrop = deliverBackdrop
    }

    func onStateChanged(_ state: Int32, errorCode: Int32, message: String?) {
        deliver(DeviceServerStateChange(state: state, errorCode: errorCode, message: message ?? ""))
    }

    func onDialog(_ dialogID: Int64, request: String?) {
        deliverDialog(dialogID, request ?? "")
    }

    func onDialogWithdrawn(_ dialogID: Int64) {
        deliverDialog(dialogID, nil)
    }

    func onBackdrop(_ image: Data?) {
        deliverBackdrop(image)
    }

    func backlightState() -> Int32 {
        LocalBacklight.state
    }
}

nonisolated final class CloudflareTunnelEvents: NSObject, LibSwiptCloudflareTunnelHandlerProtocol, @unchecked Sendable {
    private let deliver: @Sendable (_ tunnel: String, _ hostname: String) -> Void

    init(_ deliver: @escaping @Sendable (_ tunnel: String, _ hostname: String) -> Void) {
        self.deliver = deliver
    }

    func onState(_ tunnel: String?, hostname: String?) {
        deliver(tunnel ?? "", hostname ?? "")
    }
}

nonisolated final class DiskImageImportEvents: NSObject, LibSwiptDiskImageImportHandlerProtocol, @unchecked Sendable {
    private let deliver: @Sendable (DiskImageImportProgress) -> Void

    init(_ deliver: @escaping @Sendable (DiskImageImportProgress) -> Void) {
        self.deliver = deliver
    }

    func onProgress(_ received: Int64, total: Int64) {
        deliver(DiskImageImportProgress(received: received, total: total > 0 ? total : nil))
    }
}

nonisolated final class ScriptEvents: NSObject, LibSwiptScriptObserverProtocol, @unchecked Sendable {
    private let deliverWaiting: @Sendable () -> Void
    private let deliverRequest: @Sendable (String) -> Void

    init(waiting deliverWaiting: @escaping @Sendable () -> Void, request deliverRequest: @escaping @Sendable (String) -> Void) {
        self.deliverWaiting = deliverWaiting
        self.deliverRequest = deliverRequest
    }

    func onWaiting() {
        deliverWaiting()
    }

    func onRequest(_ request: String?) {
        deliverRequest(request ?? "")
    }
}

nonisolated enum PairingEvent: Sendable {
    case pin(String)
    case paired(Data)
    case failed(errorCode: Int32, message: String)
}

nonisolated final class PairingEvents: NSObject, LibSwiptPairingHandlerProtocol, @unchecked Sendable {
    private let deliver: @Sendable (PairingEvent) -> Void

    init(_ deliver: @escaping @Sendable (PairingEvent) -> Void) {
        self.deliver = deliver
    }

    func onPIN(_ pin: String?) {
        deliver(.pin(pin ?? ""))
    }

    func onPaired(_ record: Data?) {
        deliver(.paired(record ?? Data()))
    }

    func onPairingFailed(_ errorCode: Int32, message: String?) {
        deliver(.failed(errorCode: errorCode, message: message ?? ""))
    }
}
