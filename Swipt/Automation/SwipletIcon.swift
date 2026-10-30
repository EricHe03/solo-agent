import Foundation
import LibSwipt
import SwiftUI
import UIKit

nonisolated struct SwipletIcon: Hashable, Sendable {
    static let `default` = SwipletIcon(color: "grayBrown", symbol: "square.2.layers.3d.fill")

    var color: String
    var symbol: String
    var image: UIImage?

    static func load(from swiplet: URL) -> SwipletIcon {
        var icon = SwipletIcon.default
        if let loaded = LibSwiptLoadSwipletIcon(swiplet.path) {
            icon.color = loaded.color
            icon.symbol = loaded.symbol
        }
        icon.image = UIImage(contentsOfFile: swiplet.appendingPathComponent(LibSwiptSwipletIconFile).path)
        return icon
    }
}

@available(iOS 27, *)
@MainActor
extension SwipletIcon {
    var palette: SwipletIconColor {
        SwipletIconCatalog.colors.first { $0.id == color } ?? SwipletIconCatalog.colors.first { $0.id == Self.default.color }!
    }

    var gradient: LinearGradient {
        let palette = palette
        return LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
    }
}

@available(iOS 27, *)
struct SwipletIconImage: View {
    let icon: SwipletIcon
    var size: CGFloat = 24

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        if let image = icon.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            SwipletIconGlyph(symbol: icon.symbol, pointSize: size * 0.6)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(icon.gradient, in: shape)
        }
    }
}

@available(iOS 27, *)
struct SwipletIconGlyph: View {
    let symbol: String
    let pointSize: CGFloat

    var body: some View {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize)
        let image = UIImage(systemName: symbol, withConfiguration: configuration)
        let symbol = image == nil ? SwipletIcon.default.symbol : symbol
        let size = (image ?? UIImage(systemName: symbol, withConfiguration: configuration))?.size ?? .zero
        Image(systemName: symbol)
            .font(.system(size: pointSize))
            .scaleEffect(min(1, pointSize * 1.4 / max(size.width, size.height, 1)))
    }
}
