import SwiftUI

struct LoopbackRequiredView: View {
    var body: some View {
        ContentUnavailableViewCompat {
            Label("Loopback VPN Required", systemImage: "network.slash")
        } description: {
            Text("No loopback address found. Turn on [LocalDevVPN](https://apps.apple.com/app/id6755608044), or [sing-box](https://sing-box.sagernet.org) with `loopback_address` configured.")
        }
    }
}
