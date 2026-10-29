import Foundation
import SwiftUI
import UIKit

@available(iOS 27, *)
struct WorkflowIconPicker: View {
    private struct SymbolItem: Identifiable {
        let section: String
        let symbol: String

        var id: String { section + "/" + symbol }
    }

    private static let colorColumns = 5
    private static let colorCellSize: CGFloat = 60
    private static let symbolColumns = [GridItem(.adaptive(minimum: 54), spacing: 0)]
    private static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
    private static let searchIndex = WorkflowIconCatalog.categories.reduce(into: [String: String]()) { index, category in
        for symbol in category.symbols {
            index[symbol] = (WorkflowIconCatalog.searchTerms[symbol] ?? [])
                .joined(separator: "\n")
                .folding(options: searchOptions, locale: nil)
        }
    }

    @Binding private var icon: WorkflowIcon
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    init(icon: Binding<WorkflowIcon>) {
        _icon = icon
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if query.isEmpty {
                        colorCard
                    }
                    symbolCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton { dismiss() }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                }
            }
        }
        .frame(idealWidth: 390, idealHeight: 1600)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
    }

    private var colorCard: some View {
        let colors = WorkflowIconCatalog.colors
        let selected = icon.palette.id
        return VStack(spacing: 16) {
            ForEach(Array(stride(from: 0, to: colors.count, by: Self.colorColumns)), id: \.self) { start in
                HStack(spacing: 0) {
                    ForEach(start..<start + Self.colorColumns, id: \.self) { index in
                        if index > start {
                            Spacer(minLength: 0)
                        }
                        if index < colors.count {
                            colorButton(colors[index], isSelected: colors[index].id == selected)
                        } else {
                            Color.clear
                                .frame(width: Self.colorCellSize, height: Self.colorCellSize)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: cardShape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Icon Color"))
    }

    private func colorButton(_ color: WorkflowIconColor, isSelected: Bool) -> some View {
        Button {
            icon.color = color.id
        } label: {
            Circle()
                .fill(LinearGradient(colors: [color.top, color.bottom], startPoint: .top, endPoint: .bottom))
                .padding(6)
                .frame(width: Self.colorCellSize, height: Self.colorCellSize)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.tint, lineWidth: 3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(color.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbolCard: some View {
        let tokens = query.folding(options: Self.searchOptions, locale: nil).split(whereSeparator: \.isWhitespace)
        var seen = Set<String>()
        let results = WorkflowIconCatalog.categories.flatMap(\.symbols).filter { symbol in
            tokens.allSatisfy { Self.searchIndex[symbol, default: ""].contains($0) } && seen.insert(symbol).inserted
        }
        return VStack(spacing: 0) {
            SymbolSearchBar(text: $query)
                .padding(.horizontal, 8)
                .padding(.top, 5)
            if tokens.isEmpty {
                LazyVGrid(columns: Self.symbolColumns, spacing: 0) {
                    ForEach(WorkflowIconCatalog.categories) { category in
                        Section {
                            ForEach(category.symbols.map { SymbolItem(section: category.id, symbol: $0) }) { symbolButton($0.symbol) }
                        } header: {
                            Text(category.title)
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 9)
                                .padding(.top, category.id == WorkflowIconCatalog.categories.first?.id ? 12 : 16)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else if results.isEmpty {
                ContentUnavailableView("No Symbols Found", systemImage: "magnifyingglass")
                    .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: Self.symbolColumns, spacing: 0) {
                    ForEach(results, id: \.self, content: symbolButton)
                }
                .padding(8)
            }
        }
        .background(.fill.quaternary, in: cardShape)
    }

    private func symbolButton(_ symbol: String) -> some View {
        let isSelected = symbol == icon.symbol
        return Button {
            icon.symbol = symbol
        } label: {
            WorkflowIconGlyph(symbol: symbol, pointSize: 28)
                .foregroundStyle(isSelected ? HierarchicalShapeStyle.primary : .secondary)
                .frame(width: 50, height: 50)
                .background {
                    if isSelected {
                        Circle()
                            .fill(.fill.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@available(iOS 27, *)
private struct SymbolSearchBar: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar()
        searchBar.searchBarStyle = .minimal
        searchBar.placeholder = String(localized: "Search Symbols")
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.delegate = context.coordinator
        return searchBar
    }

    func updateUIView(_ searchBar: UISearchBar, context: Context) {
        context.coordinator.text = $text
        if searchBar.text != text {
            searchBar.text = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISearchBar, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: 0)).height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            text.wrappedValue = searchText
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }
}
