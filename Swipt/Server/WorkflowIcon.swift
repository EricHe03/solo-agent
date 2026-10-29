import Foundation
import LibSwipt
import SwiftUI
import UIKit

nonisolated struct WorkflowIcon: Codable, Hashable, Sendable {
    static let `default` = WorkflowIcon(color: "grayBrown", symbol: "square.2.layers.3d.fill")

    var color: String
    var symbol: String

    static func load(from workflow: URL) -> WorkflowIcon {
        guard let icon = LibSwiptLoadWorkflowIcon(workflow.path) else { return .default }
        return WorkflowIcon(color: icon.color, symbol: icon.symbol)
    }

    func save(to workflow: URL) throws {
        var error: NSError?
        LibSwiptSaveWorkflowIcon(workflow.path, color, symbol, &error)
        if let error { throw error }
    }
}

@available(iOS 27, *)
@MainActor
extension WorkflowIcon {
    var palette: WorkflowIconColor {
        WorkflowIconCatalog.colors.first { $0.id == color } ?? WorkflowIconCatalog.colors.first { $0.id == Self.default.color }!
    }

    var gradient: LinearGradient {
        let palette = palette
        return LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)
    }
}

@available(iOS 27, *)
struct WorkflowIconImage: View {
    let icon: WorkflowIcon
    var size: CGFloat = 24

    var body: some View {
        WorkflowIconGlyph(symbol: icon.symbol, pointSize: size * 0.6)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(icon.gradient, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

@available(iOS 27, *)
struct WorkflowIconGlyph: View {
    let symbol: String
    let pointSize: CGFloat

    var body: some View {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize)
        let image = UIImage(systemName: symbol, withConfiguration: configuration)
        let symbol = image == nil ? WorkflowIcon.default.symbol : symbol
        let size = (image ?? UIImage(systemName: symbol, withConfiguration: configuration))?.size ?? .zero
        Image(systemName: symbol)
            .font(.system(size: pointSize))
            .scaleEffect(min(1, pointSize * 1.4 / max(size.width, size.height, 1)))
    }
}
