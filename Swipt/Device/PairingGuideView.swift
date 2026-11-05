import SwiftUI
import UIKit

struct PairingGuideView: View {
    let hostName: String

    private static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    private static var size: CGSize { isPad ? CGSize(width: 652, height: 134) : CGSize(width: 272, height: 252) }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / Self.size.width
            context.scaleBy(x: scale, y: scale)
            var painter = GuidePainter(context: context, hostName: hostName)
            if Self.isPad {
                painter.drawPad(width: Self.size.width)
            } else {
                painter.drawPhone(width: Self.size.width)
            }
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .frame(maxWidth: Self.isPad ? nil : 245)
        .accessibilityHidden(true)
    }
}

private struct GuideRow {
    var icon: Color?
    var label: Text?
    var highlighted = false
    var toggle = false
    var chevron = true

    static func blank(_ icon: Color? = Color(.systemGray)) -> GuideRow {
        GuideRow(icon: icon)
    }
}

private enum GuideBlock {
    case header(Text)
    case group([GuideRow])
}

private struct GuideScroll {
    var position: CGFloat
    var length: CGFloat
}

private struct GuideList {
    var title: Text
    var back = false
    var sidebarSelected = false
    var blocks: [GuideBlock]
    var scroll: GuideScroll?
}

private enum GuideScreen {
    case list(GuideList)
    case code
}

private struct GuidePainter {
    var context: GraphicsContext
    let hostName: String

    private let frameStroke = Color(.systemGray3)
    private let groupFill = Color(.tertiarySystemFill)
    private let barFill = Color(.systemFill)
    private let separator = Color(.separator)
    private let indicator = Color(.systemGray2)

    private var hostRow: Text { Text(verbatim: "Pair with \(hostName)") }

    private var pairRows: [GuideRow] {
        [GuideRow(icon: Color(.systemGreen), label: Text("Face ID & Passcode")),
         GuideRow(icon: Color(.systemRed), label: Text("Emergency SOS")),
         GuideRow(icon: Color(.systemBlue), label: Text("Privacy & Security"), highlighted: true)]
    }

    private func securityRows(all: Bool) -> [GuideRow] {
        var rows = [
            GuideRow(icon: Color(.systemGray), label: Text("Developer Mode"), highlighted: true),
            GuideRow(icon: Color(.systemGray), label: Text("Wired Accessories")),
            GuideRow(icon: Color(.systemBlue), label: Text("Background Security Improvements")),
        ]
        if all {
            rows.append(GuideRow(icon: Color(.systemBlue), label: Text("Stolen Device Protection")))
        }
        return rows
    }

    private var developerMode: GuideList {
        GuideList(
            title: Text("Developer Mode"), back: true,
            blocks: [.group([GuideRow(label: Text("Developer Mode"), toggle: true)]),
                     .header(Text("Paired Devices")), .group([.blank(nil)]),
                     .header(Text("Other Devices")), .group([GuideRow(label: hostRow, highlighted: true)])])
    }

    mutating func drawPhone(width canvasWidth: CGFloat) {
        let settings = GuideList(
            title: Text("Settings"),
            blocks: [.group(Array(repeating: .blank(), count: 2)), .group(pairRows), .group(Array(repeating: .blank(), count: 2))],
            scroll: GuideScroll(position: 0.97, length: 0.45))
        let privacy = GuideList(
            title: Text("Privacy & Security"), back: true,
            blocks: [.group([.blank()]), .header(Text("Transparency Logs")), .group([.blank()]),
                     .header(Text("Security")), .group(securityRows(all: true))],
            scroll: GuideScroll(position: 0.95, length: 0.32))
        let rows: [[GuideScreen]] = [[.list(settings), .list(privacy)], [.list(developerMode), .code]]
        for (screen, frame) in place(rows, size: CGSize(width: 120, height: 116), gap: 28, rowGap: 16, canvasWidth: canvasWidth) {
            var cropped = context
            cropped.clip(to: Path(frame.insetBy(dx: -2, dy: -2)))
            let device = CGRect(origin: frame.origin, size: CGSize(width: frame.width, height: frame.height + 40))
            cropped.stroke(Path(roundedRect: device, cornerRadius: 18), with: .color(frameStroke), lineWidth: 2.5)
            cropped.fill(Path(roundedRect: CGRect(x: frame.midX - 16, y: frame.minY + 7, width: 32, height: 5), cornerRadius: 2.5), with: .color(frameStroke))
            var inner = cropped
            inner.clip(to: Path(roundedRect: device.insetBy(dx: 2, dy: 2).divided(atDistance: 14, from: .minYEdge).remainder, cornerRadius: 12))
            var page = GuidePainter(context: inner, hostName: hostName)
            page.drawPhoneScreen(screen, in: frame)
            var fade = context
            fade.blendMode = .destinationOut
            fade.fill(
                Path(CGRect(x: frame.minX - 2, y: frame.maxY - 14, width: frame.width + 4, height: 16)),
                with: .linearGradient(Gradient(colors: [.clear, .black]), startPoint: CGPoint(x: frame.midX, y: frame.maxY - 14), endPoint: CGPoint(x: frame.midX, y: frame.maxY)))
        }
    }

    mutating func drawPad(width canvasWidth: CGFloat) {
        let privacy = GuideList(
            title: Text("Privacy & Security"), sidebarSelected: true,
            blocks: [.group(Array(repeating: .blank(), count: 2)), .header(Text("Transparency Logs")), .group([.blank()]),
                     .header(Text("Security")), .group(securityRows(all: false)), .group([.blank()])],
            scroll: GuideScroll(position: 0.92, length: 0.28))
        let rows: [[GuideScreen]] = [[.list(privacy), .list(developerMode), .code]]
        for (screen, frame) in place(rows, size: CGSize(width: 200, height: 130), gap: 24, rowGap: 0, canvasWidth: canvasWidth) {
            context.stroke(Path(roundedRect: frame, cornerRadius: 12), with: .color(frameStroke), lineWidth: 2.5)
            var inner = context
            inner.clip(to: Path(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: 10))
            var page = GuidePainter(context: inner, hostName: hostName)
            page.drawPadScreen(screen, in: frame)
        }
    }

    private mutating func place(_ rows: [[GuideScreen]], size: CGSize, gap: CGFloat, rowGap: CGFloat, canvasWidth: CGFloat) -> [(GuideScreen, CGRect)] {
        var placed: [(GuideScreen, CGRect)] = []
        for (row, screens) in rows.enumerated() {
            let left = (canvasWidth - CGFloat(screens.count) * (size.width + gap) + gap) / 2
            for (column, screen) in screens.enumerated() {
                let frame = CGRect(origin: CGPoint(x: left + CGFloat(column) * (size.width + gap), y: 2 + CGFloat(row) * (size.height + rowGap)), size: size)
                if column > 0 {
                    drawChevron(at: CGPoint(x: frame.minX - gap / 2, y: frame.midY))
                }
                placed.append((screen, frame))
            }
        }
        return placed
    }

    private mutating func drawPhoneScreen(_ screen: GuideScreen, in frame: CGRect) {
        switch screen {
        case .list(let list):
            drawPhoneList(list, in: frame)
        case .code:
            drawCode(in: frame.divided(atDistance: 18, from: .minYEdge).remainder, bannerWidth: frame.width - 12)
        }
    }

    private mutating func drawPhoneList(_ list: GuideList, in frame: CGRect) {
        drawTitle(list.title, back: list.back, in: CGRect(x: frame.minX, y: frame.minY + 17, width: frame.width, height: 10))
        drawBlocks(list.blocks, in: CGRect(x: frame.minX + 9, y: frame.minY + 29, width: frame.width - 18, height: frame.height - 31), rowHeight: 12)
        if let scroll = list.scroll {
            drawScroll(scroll, x: frame.maxX - 4.5, top: frame.minY + 24, height: frame.height - 30)
        }
    }

    private mutating func drawPadScreen(_ screen: GuideScreen, in frame: CGRect) {
        switch screen {
        case .list(let list):
            drawPadList(list, in: frame)
        case .code:
            drawCode(in: frame.insetBy(dx: 2, dy: 2), bannerWidth: 112)
            let close = CGRect(x: frame.minX + 6, y: frame.minY + 6, width: 11, height: 11)
            context.fill(Path(ellipseIn: close), with: .color(groupFill))
            var cross = Path()
            cross.move(to: CGPoint(x: close.minX + 3.5, y: close.minY + 3.5))
            cross.addLine(to: CGPoint(x: close.maxX - 3.5, y: close.maxY - 3.5))
            cross.move(to: CGPoint(x: close.maxX - 3.5, y: close.minY + 3.5))
            cross.addLine(to: CGPoint(x: close.minX + 3.5, y: close.maxY - 3.5))
            context.stroke(cross, with: .color(.primary), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }
    }

    private mutating func drawPadList(_ list: GuideList, in frame: CGRect) {
        let side = CGRect(x: frame.minX + 2, y: frame.minY + 2, width: 70, height: frame.height - 4)
        context.fill(Path(side), with: .color(groupFill))
        context.fill(Path(roundedRect: CGRect(x: side.minX + 6, y: side.minY + 6, width: side.width - 12, height: 7), cornerRadius: 3.5), with: .color(barFill))
        var sideRows = pairRows
        sideRows.remove(at: 1)
        sideRows[1].highlighted = list.sidebarSelected
        for row in sideRows.indices {
            sideRows[row].chevron = false
        }
        drawBlocks(
            [.group(Array(repeating: .blank(), count: 3)), .group(sideRows), .group(Array(repeating: .blank(), count: 3))],
            in: CGRect(x: side.minX + 6, y: side.minY + 18, width: side.width - 12, height: side.height), rowHeight: 10)
        drawScroll(GuideScroll(position: 0.98, length: 0.35), x: side.maxX - 3, top: side.minY + 5, height: side.height - 10)
        drawTitle(list.title, back: list.back, in: CGRect(x: side.maxX, y: frame.minY + 6, width: frame.maxX - side.maxX, height: 9))
        drawBlocks(list.blocks, in: CGRect(x: side.maxX + 6, y: frame.minY + 18, width: frame.maxX - side.maxX - 14, height: frame.height), rowHeight: 11)
        if let scroll = list.scroll {
            drawScroll(scroll, x: frame.maxX - 4.5, top: frame.minY + 6, height: frame.height - 12)
        }
    }

    private mutating func drawCode(in rect: CGRect, bannerWidth: CGFloat) {
        let banner = CGRect(x: rect.midX - bannerWidth / 2, y: rect.minY + 4, width: bannerWidth, height: 24)
        context.fill(Path(roundedRect: banner, cornerRadius: 9), with: .color(groupFill))
        drawHighlight(banner, cornerRadius: 9)
        let icon = CGRect(x: banner.minX + 5, y: banner.midY - 6, width: 12, height: 12)
        context.fill(Path(roundedRect: icon, cornerRadius: 3), with: .color(Color(red: 0.92549, green: 0.93725, blue: 0.94510)))
        context.draw(Image("SwiptIcon"), in: icon)
        let ring = CGRect(x: banner.maxX - 15, y: banner.midY - 5, width: 10, height: 10)
        context.stroke(Path(ellipseIn: ring), with: .color(.primary), lineWidth: 1.2)
        context.fill(Path(roundedRect: ring.insetBy(dx: 3.4, dy: 3.4), cornerRadius: 0.6), with: .color(.primary))
        let available = ring.minX - icon.maxX - 8
        drawFitted(Text("Pairing Code: \("123 456")"), size: 5.5, weight: .bold, color: .primary, available: available, at: CGPoint(x: icon.maxX + 4, y: banner.midY - 3.5), anchor: .leading)
        drawFitted(Text("Privacy & Security › Developer Mode"), size: 4.2, weight: .regular, color: .secondary, available: available, at: CGPoint(x: icon.maxX + 4, y: banner.midY + 3.5), anchor: .leading)
        let middle = (banner.maxY + rect.maxY) / 2
        for (index, length) in [34.0, 46.0].enumerated() {
            context.fill(Path(roundedRect: CGRect(x: rect.midX - length / 2, y: middle - 16 + CGFloat(index) * 6.5, width: length, height: 4), cornerRadius: 2), with: .color(indicator))
        }
        for index in 0..<6 {
            context.fill(Path(roundedRect: CGRect(x: rect.midX - 26.5 + CGFloat(index) * 9.5, y: middle + 2, width: 6, height: 1.5), cornerRadius: 0.75), with: .color(.primary))
        }
    }

    private mutating func drawHighlight(_ rect: CGRect, cornerRadius: CGFloat) {
        context.fill(Path(roundedRect: rect, cornerRadius: cornerRadius), with: .color(.accentColor.opacity(0.28)))
        context.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: cornerRadius - 0.5), with: .color(.accentColor), lineWidth: 1.2)
    }

    private mutating func drawFitted(_ text: Text, size: CGFloat, weight: Font.Weight, color: Color, available: CGFloat, at point: CGPoint, anchor: UnitPoint) {
        var resolved = context.resolve(text.font(.system(size: size, weight: weight)).foregroundColor(color))
        let width = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
        if width > available {
            resolved = context.resolve(text.font(.system(size: size * available / width, weight: weight)).foregroundColor(color))
        }
        context.draw(resolved, at: point, anchor: anchor)
    }

    private mutating func drawTitle(_ title: Text, back: Bool, in rect: CGRect) {
        drawFitted(title, size: 6.5, weight: .semibold, color: .primary, available: rect.width - 30, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        if back {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 13, y: rect.midY - 3.5))
            path.addLine(to: CGPoint(x: rect.minX + 10, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + 13, y: rect.midY + 3.5))
            context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }

    private mutating func drawBlocks(_ blocks: [GuideBlock], in rect: CGRect, rowHeight: CGFloat) {
        var y = rect.minY
        for block in blocks {
            switch block {
            case .header(let text):
                context.draw(text.font(.system(size: 5.5)).foregroundColor(.secondary), at: CGPoint(x: rect.minX + 5, y: y + 4), anchor: .leading)
                y += 9
            case .group(let rows):
                let group = CGRect(x: rect.minX, y: y, width: rect.width, height: CGFloat(rows.count) * rowHeight)
                context.fill(Path(roundedRect: group, cornerRadius: 5), with: .color(groupFill))
                for (index, row) in rows.enumerated() {
                    drawRow(row, in: CGRect(x: group.minX, y: group.minY + CGFloat(index) * rowHeight, width: group.width, height: rowHeight),
                            separator: index > 0 && !row.highlighted && !rows[index - 1].highlighted)
                }
                y = group.maxY + 8
            }
        }
    }

    private mutating func drawRow(_ row: GuideRow, in rect: CGRect, separator: Bool) {
        let textX = rect.minX + (row.icon == nil && row.label != nil && !row.highlighted || row.icon == nil ? 6 : 18)
        if row.highlighted {
            drawHighlight(rect, cornerRadius: 5)
        } else if separator {
            context.fill(Path(CGRect(x: textX, y: rect.minY, width: rect.maxX - textX - 5, height: 0.5)), with: .color(self.separator))
        }
        if let icon = row.icon {
            let side = min(8, rect.height - 3)
            context.fill(Path(roundedRect: CGRect(x: rect.minX + 5, y: rect.midY - side / 2, width: side, height: side), cornerRadius: 2), with: .color(icon))
        }
        let trailing: CGFloat = row.toggle ? 22 : row.chevron ? 10 : 4
        if let label = row.label {
            drawFitted(label, size: 5.5, weight: row.highlighted ? .bold : .medium, color: .primary, available: rect.maxX - textX - trailing, at: CGPoint(x: textX, y: rect.midY), anchor: .leading)
        } else {
            context.fill(Path(roundedRect: CGRect(x: textX, y: rect.midY - 2, width: rect.width * 0.45, height: 4), cornerRadius: 2), with: .color(barFill))
        }
        if row.toggle {
            let toggle = CGRect(x: rect.maxX - 19, y: rect.midY - 3.5, width: 13, height: 7)
            context.fill(Path(roundedRect: toggle, cornerRadius: 3.5), with: .color(Color(.systemGreen)))
            context.fill(Path(ellipseIn: CGRect(x: toggle.maxX - 6.5, y: toggle.minY + 0.5, width: 6, height: 6)), with: .color(.white))
        } else if row.chevron, row.label != nil, !row.highlighted {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX - 8, y: rect.midY - 2.2))
            path.addLine(to: CGPoint(x: rect.maxX - 5.8, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.midY + 2.2))
            context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
        }
    }

    private mutating func drawScroll(_ scroll: GuideScroll, x: CGFloat, top: CGFloat, height: CGFloat) {
        let length = height * scroll.length
        let rect = CGRect(x: x, y: top + (height - length) * scroll.position, width: 2.2, height: length)
        context.fill(Path(roundedRect: rect, cornerRadius: 1.1), with: .color(indicator))
    }

    private mutating func drawChevron(at point: CGPoint) {
        var path = Path()
        path.move(to: CGPoint(x: point.x - 4, y: point.y - 8))
        path.addLine(to: CGPoint(x: point.x + 4, y: point.y))
        path.addLine(to: CGPoint(x: point.x - 4, y: point.y + 8))
        context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}
