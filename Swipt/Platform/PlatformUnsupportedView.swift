import SwiftUI
import UIKit

struct PlatformUnsupportedView: View {
    let title: LocalizedStringKey

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var systemImage: String {
        guard #available(iOS 17.4, *) else { return "exclamationmark.triangle" }
        return isPad ? "ipad.badge.exclamationmark" : "iphone.badge.exclamationmark"
    }

    var body: some View {
        ContentUnavailableViewCompat {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                Label("Not Available on Mac", systemImage: "desktopcomputer")
            } else if isPad {
                Label("Unsupported iPadOS Version", systemImage: systemImage)
            } else {
                Label("Unsupported iOS Version", systemImage: systemImage)
            }
        } description: {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                Text("Use this app on an iPhone or iPad to automate that device.")
            } else if isPad {
                Text("Automating this iPad needs iPadOS 27 or later.")
            } else {
                Text("Automating this iPhone needs iOS 27 or later.")
            }
        }
        .navigationTitle(title)
    }
}
