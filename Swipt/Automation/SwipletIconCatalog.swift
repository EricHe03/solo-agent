import SwiftUI
import UIKit

@available(iOS 27, *)
struct SwipletIconColor: Identifiable {
    let id: String
    let top: Color
    let bottom: Color
}

@available(iOS 27, *)
enum SwipletIconCatalog {
    // VoiceShortcutClient +[WFColor workflowGradientPalette]: Display P3 base colors (light, dark, increased contrast light, increased contrast dark)
    // under a white overlay fading from 14% to 0%.
    static let colors: [SwipletIconColor] = [
        SwipletIconColor("red", light: 0xE76168, dark: 0xDB5C5C, lightIncreasedContrast: 0xC25347, darkIncreasedContrast: 0xBA4A3D),
        SwipletIconColor("orange", light: 0xF08365, dark: 0xEB7B5B, lightIncreasedContrast: 0xC05639, darkIncreasedContrast: 0xB34E32),
        SwipletIconColor("tangerine", light: 0xEBA557, dark: 0xE69D4C, lightIncreasedContrast: 0xA8651A, darkIncreasedContrast: 0xA15E13),
        SwipletIconColor("yellow", light: 0xF0BB40, dark: 0xDEBC33, lightIncreasedContrast: 0xA88B15, darkIncreasedContrast: 0x856D0D),
        SwipletIconColor("lime", light: 0x65C261, dark: 0x58B854, lightIncreasedContrast: 0x3B7B39, darkIncreasedContrast: 0x377B34),
        SwipletIconColor("teal", light: 0x2AC7A8, dark: 0x26BFA1, lightIncreasedContrast: 0x147561, darkIncreasedContrast: 0x0F6E5B),
        SwipletIconColor("cyan", light: 0x3EACF0, dark: 0x76BEE6, lightIncreasedContrast: 0x0D679F, darkIncreasedContrast: 0x065C91),
        SwipletIconColor("blue", light: 0x3B7FF7, dark: 0x3B82F7, lightIncreasedContrast: 0x183FD5, darkIncreasedContrast: 0x5A9AF8),
        SwipletIconColor("navy", light: 0x425BB8, dark: 0x425BB8, lightIncreasedContrast: 0x0D679F, darkIncreasedContrast: 0x065C91),
        SwipletIconColor("grape", light: 0x784DB8, dark: 0x6C43A8, lightIncreasedContrast: 0x543485, darkIncreasedContrast: 0x4A2F73),
        SwipletIconColor("purple", light: 0xAC74DC, dark: 0x9F67CF, lightIncreasedContrast: 0x7E5C94, darkIncreasedContrast: 0x6E4D85),
        SwipletIconColor("pink", light: 0xE689CE, dark: 0xD979C0, lightIncreasedContrast: 0xB25870, darkIncreasedContrast: 0xA1475F),
        SwipletIconColor("grayBlue", light: 0x808993, dark: 0x79828C, lightIncreasedContrast: 0x5F666E, darkIncreasedContrast: 0x515A63),
        SwipletIconColor("grayGreen", light: 0x8DA28F, dark: 0x8DA28F, lightIncreasedContrast: 0x747D74, darkIncreasedContrast: 0x687368),
        SwipletIconColor("grayBrown", light: 0xA28B6E, dark: 0xAF997C, lightIncreasedContrast: 0x7F7773, darkIncreasedContrast: 0x80726E),
    ]
}

@available(iOS 27, *)
extension SwipletIconColor {
    fileprivate init(
        _ id: String,
        light: UInt32,
        dark: UInt32,
        lightIncreasedContrast: UInt32,
        darkIncreasedContrast: UInt32
    ) {
        let variants = [light, dark, lightIncreasedContrast, darkIncreasedContrast]
        self.init(
            id: id,
            top: Color(uiColor: Self.displayP3(variants, white: 0.14)),
            bottom: Color(uiColor: Self.displayP3(variants, white: 0))
        )
    }

    nonisolated private static func displayP3(_ variants: [UInt32], white: CGFloat) -> UIColor {
        UIColor { traits in
            let increasedContrast = traits.accessibilityContrast == .high
            let value = switch traits.userInterfaceStyle {
            case .dark: increasedContrast ? variants[3] : variants[1]
            default: increasedContrast ? variants[2] : variants[0]
            }
            let components = [16, 8, 0].map { shift in
                let component = CGFloat((value >> UInt32(shift)) & 0xFF) / 255
                return component + (1 - component) * white
            }
            return UIColor(displayP3Red: components[0], green: components[1], blue: components[2], alpha: 1)
        }
    }
}
