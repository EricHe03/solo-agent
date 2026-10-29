import Foundation
import LibSwipt

nonisolated struct ServerProblem: Equatable, LocalizedError {
    enum Kind: Sendable {
        case noTunnel
        case pairingRejected
        case developerModeOff
        case noDiskImage
        case diskImage
        case listen
        case unsupported
        case screenInUse
        case pairing
        case loopbackAddress
        case locationDenied
        case other
    }

    var kind: Kind
    var message: String
}

extension ServerProblem {
    init(code: Int32, message: String) {
        let kind: Kind =
            switch code {
            case LibSwiptDeviceErrorNoTunnel: .noTunnel
            case LibSwiptDeviceErrorPairingRejected: .pairingRejected
            case LibSwiptDeviceErrorDeveloperModeOff: .developerModeOff
            case LibSwiptDeviceErrorNoDiskImage: .noDiskImage
            case LibSwiptDeviceErrorDiskImage: .diskImage
            case LibSwiptDeviceErrorListen: .listen
            case LibSwiptDeviceErrorUnsupported: .unsupported
            case LibSwiptDeviceErrorScreenInUse: .screenInUse
            case LibSwiptDeviceErrorPairing: .pairing
            case LibSwiptDeviceErrorLoopbackAddress: .loopbackAddress
            default: .other
            }
        self.init(kind: kind, message: message)
    }

    var errorDescription: String? {
        message.isEmpty ? title : "\(title): \(message)"
    }

    var title: String {
        switch kind {
        case .noTunnel: String(localized: "Waiting for the VPN")
        case .pairingRejected: String(localized: "This Device Rejected the Pairing")
        case .developerModeOff: String(localized: "Developer Mode Is Off")
        case .noDiskImage: String(localized: "No Developer Disk Image")
        case .diskImage: String(localized: "Couldn’t Mount the Developer Disk Image")
        case .listen: String(localized: "A Port Is in Use")
        case .unsupported: String(localized: "This Device Isn’t Supported")
        case .screenInUse: String(localized: "The Screen Is Shared Elsewhere")
        case .pairing: String(localized: "Pairing Failed")
        case .loopbackAddress: String(localized: "The VPN Gives a Loopback Address")
        case .locationDenied: String(localized: "No Location Access")
        case .other: String(localized: "Server Stopped")
        }
    }
}
