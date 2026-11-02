import SwiftUI
import UIKit

struct PairingGuideView: View {
    let hostName: String

    private static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    private static var size: CGSize { isPad ? CGSize(width: 660, height: 200) : CGSize(width: 416, height: 230) }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / Self.size.width
            context.scaleBy(x: scale, y: scale)
            var painter = GuidePainter(context: context, hostName: hostName)
            if Self.isPad {
                painter.drawPad()
            } else {
                painter.drawPhone()
            }
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
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

private struct GuidePainter {
    var context: GraphicsContext
    let hostName: String

    private let frameStroke = Color(.systemGray3)
    private let groupFill = Color(.tertiarySystemFill)
    private let barFill = Color(.systemFill)
    private let separator = Color(.separator)
    private let indicator = Color(.systemGray2)

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

    private var developerModeBlocks: [GuideBlock] {
        [.group([GuideRow(label: Text("Developer Mode"), toggle: true)]),
         .header(Text("Paired Devices")), .group([.blank(nil), .blank(nil)]),
         .header(Text("Other Devices")), .group([GuideRow(label: Text(verbatim: "Pair with \(hostName)"), highlighted: true)])]
    }

    mutating func drawPhone() {
        let width: CGFloat = 120
        let height: CGFloat = 230
        let gap: CGFloat = 28
        let screens: [(Text, Bool, [GuideBlock], GuideScroll?)] = [
            (Text("Settings"), false,
             [.group(Array(repeating: .blank(), count: 3)), .group(Array(repeating: .blank(), count: 4)), .group(pairRows), .group(Array(repeating: .blank(), count: 3))],
             GuideScroll(position: 0.97, length: 0.45)),
            (Text("Privacy & Security"), true,
             [.group(Array(repeating: .blank(), count: 2)), .header(Text("Transparency Logs")), .group(Array(repeating: .blank(), count: 2)),
              .header(Text("Security")), .group(securityRows(all: true)), .group([.blank()])],
             GuideScroll(position: 0.95, length: 0.32)),
            (Text("Developer Mode"), true, developerModeBlocks, nil),
        ]
        for (index, screen) in screens.enumerated() {
            let origin = CGPoint(x: CGFloat(index) * (width + gap), y: 0)
            if index > 0 {
                drawChevron(at: CGPoint(x: origin.x - gap / 2, y: height / 2))
            }
            let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
            context.stroke(Path(roundedRect: frame, cornerRadius: 18), with: .color(frameStroke), lineWidth: 2.5)
            context.fill(Path(roundedRect: CGRect(x: frame.midX - 16, y: frame.minY + 7, width: 32, height: 5), cornerRadius: 2.5), with: .color(frameStroke))
            var inner = context
            inner.clip(to: Path(roundedRect: frame.insetBy(dx: 2, dy: 2).divided(atDistance: 14, from: .minYEdge).remainder, cornerRadius: 12))
            var page = GuidePainter(context: inner, hostName: hostName)
            page.drawTitle(screen.0, back: screen.1, in: CGRect(x: frame.minX, y: frame.minY + 17, width: width, height: 10))
            page.drawBlocks(screen.2, in: CGRect(x: frame.minX + 9, y: frame.minY + 32, width: width - 18, height: height - 34), rowHeight: 14)
            if let scroll = screen.3 {
                page.drawScroll(scroll, x: frame.maxX - 4.5, top: frame.minY + 24, height: height - 30)
            }
        }
    }

    mutating func drawPad() {
        let width: CGFloat = 300
        let height: CGFloat = 200
        let sidebar: CGFloat = 104
        let gap: CGFloat = 60
        let details: [(Text, Bool, [GuideBlock], GuideScroll?)] = [
            (Text("Privacy & Security"), false,
             [.group(Array(repeating: .blank(), count: 2)), .header(Text("Transparency Logs")), .group([.blank()]),
              .header(Text("Security")), .group(securityRows(all: false)), .group([.blank()])],
             GuideScroll(position: 0.92, length: 0.28)),
            (Text("Developer Mode"), true, developerModeBlocks, nil),
        ]
        for (index, detail) in details.enumerated() {
            let origin = CGPoint(x: CGFloat(index) * (width + gap), y: 0)
            if index > 0 {
                drawChevron(at: CGPoint(x: origin.x - gap / 2, y: height / 2))
            }
            let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
            context.stroke(Path(roundedRect: frame, cornerRadius: 14), with: .color(frameStroke), lineWidth: 2.5)
            var inner = context
            inner.clip(to: Path(roundedRect: frame.insetBy(dx: 2, dy: 2), cornerRadius: 12))
            var page = GuidePainter(context: inner, hostName: hostName)
            let side = CGRect(x: frame.minX + 2, y: frame.minY + 2, width: sidebar, height: height - 4)
            page.context.fill(Path(side), with: .color(groupFill))
            page.context.fill(Path(roundedRect: CGRect(x: side.minX + 7, y: side.minY + 10, width: sidebar - 14, height: 10), cornerRadius: 5), with: .color(barFill))
            var sideRows = pairRows
            sideRows.remove(at: 1)
            sideRows[1].highlighted = index == 0
            for row in sideRows.indices {
                sideRows[row].chevron = false
            }
            page.drawBlocks(
                [.group(Array(repeating: .blank(), count: 3)), .group(sideRows), .group(Array(repeating: .blank(), count: 3))],
                in: CGRect(x: side.minX + 7, y: side.minY + 28, width: sidebar - 14, height: height), rowHeight: 14)
            page.drawScroll(GuideScroll(position: 0.98, length: 0.35), x: side.maxX - 3.5, top: side.minY + 6, height: side.height - 12)
            let content = CGRect(x: side.maxX + 10, y: frame.minY + 24, width: frame.maxX - side.maxX - 22, height: height)
            page.drawTitle(detail.0, back: detail.1, in: CGRect(x: side.maxX, y: frame.minY + 8, width: frame.maxX - side.maxX, height: 10))
            page.drawBlocks(detail.2, in: content, rowHeight: 16)
            if let scroll = detail.3 {
                page.drawScroll(scroll, x: frame.maxX - 4.5, top: frame.minY + 6, height: height - 12)
            }
        }
    }

    private mutating func drawTitle(_ title: Text, back: Bool, in rect: CGRect) {
        context.draw(title.font(.system(size: 6.5, weight: .semibold)).foregroundColor(.primary), at: CGPoint(x: rect.midX, y: rect.midY))
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
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.accentColor.opacity(0.28)))
            context.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4.5), with: .color(.accentColor), lineWidth: 1.2)
        } else if separator {
            context.fill(Path(CGRect(x: textX, y: rect.minY, width: rect.maxX - textX - 5, height: 0.5)), with: .color(self.separator))
        }
        if let icon = row.icon {
            context.fill(Path(roundedRect: CGRect(x: rect.minX + 5, y: rect.midY - 4, width: 8, height: 8), cornerRadius: 2), with: .color(icon))
        }
        let trailing: CGFloat = row.toggle ? 22 : row.chevron ? 10 : 4
        let available = rect.maxX - textX - trailing
        if let label = row.label {
            let styled = label.font(.system(size: 5.5, weight: row.highlighted ? .bold : .medium)).foregroundColor(.primary)
            var resolved = context.resolve(styled)
            let width = resolved.measure(in: CGSize(width: .infinity, height: rect.height)).width
            if width > available {
                resolved = context.resolve(label.font(.system(size: max(4, 5.5 * available / width), weight: row.highlighted ? .bold : .medium)).foregroundColor(.primary))
            }
            context.draw(resolved, at: CGPoint(x: textX, y: rect.midY), anchor: .leading)
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
