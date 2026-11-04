import SwiftUI
import UIKit

struct SetupPage<Content: View, Actions: View>: View {
    private static var textWidth: CGFloat { 520 }
    private static var contentWidth: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 760 : 520 }
    private static var actionsWidth: CGFloat { 480 }

    private let icon: String
    private let title: Text
    private let description: Text?
    private let content: Content
    private let actions: Actions

    init(_ icon: String, _ title: Text, description: Text? = nil, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.description = description
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: icon)
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                    title
                        .font(.largeTitle.bold())
                    if let description {
                        description
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: Self.textWidth)
                    }
                    content
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.contentWidth)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                actions
            }
            .frame(maxWidth: Self.actionsWidth)
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SetupPrimaryButton: View {
    let title: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            title
                .frame(maxWidth: .infinity)
        }
        .prominentButtonStyleCompat()
        .controlSize(.large)
    }
}

struct SetupSecondaryButton: View {
    let title: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            title
                .frame(maxWidth: .infinity)
        }
        .glassButtonStyleCompat()
        .controlSize(.large)
    }
}

struct SetupStepLine: View {
    let number: Int
    let text: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: 20, alignment: .trailing)
            text
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
