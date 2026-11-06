import Perception
import SwiftUI

struct AutoUnlockView: View {
    @State private var isEditing = false

    @Perception.Bindable private var settings = AutoUnlockSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    Toggle("Enabled", isOn: $settings.isEnabled)
                        .disabled(!settings.isEnabled && settings.passcodeType.problem(for: settings.passcode) != nil)
                } footer: {
                    Text("Enable automatic unlock so Solo Agent can unlock your device automatically when it’s locked.")
                }
                Section {
                    Button { isEditing = true } label: {
                        HStack {
                            Text("Passcode")
                            Spacer()
                            if settings.passcode.isEmpty {
                                Text("Not Set")
                                    .foregroundStyle(.secondary)
                            } else {
                                settings.passcodeType.title
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Automatic Unlock")
            .sheet(isPresented: $isEditing) {
                NavigationStackCompat {
                    AutoUnlockSetupView()
                }
            }
        }
    }
}

struct AutoUnlockSetupView: View {
    var next: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var passcodeType: PasscodeType? = AutoUnlockSettings.shared.passcode.isEmpty ? nil : AutoUnlockSettings.shared.passcodeType
    @State private var passcode = AutoUnlockSettings.shared.passcode
    @FocusState private var isPasscodeFocused: Bool

    private let settings = AutoUnlockSettings.shared

    private var problem: String? {
        guard let passcodeType else { return "" }
        return passcodeType.problem(for: passcode)
    }

    var body: some View {
        SetupPage("lock.open", Text("Automatic Unlock"), description: Text("Enable automatic unlock so Solo Agent can unlock your device automatically when it’s locked.")) {
            VStack(spacing: 8) {
                ForEach(PasscodeType.allCases, id: \.self) { type in
                    PasscodeTypeCard(type: type, isSelected: type == passcodeType) {
                        guard passcodeType != type else { return }
                        passcodeType = type
                        passcode = ""
                        isPasscodeFocused = true
                    }
                    if type == passcodeType {
                        passcodeField(for: type)
                    }
                }
            }
            .frame(maxWidth: 480)
        } actions: {
            if let next {
                SetupPrimaryButton(title: Text("Continue")) {
                    save()
                    next()
                }
                .disabled(problem != nil)
                SetupSecondaryButton(title: Text("No Thanks")) {
                    settings.isSetUp = true
                    next()
                }
            } else {
                SetupPrimaryButton(title: Text("Save")) {
                    save()
                    dismiss()
                }
                .disabled(problem != nil)
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if next == nil {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func passcodeField(for type: PasscodeType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Passcode", text: $passcode.masked { isPasscodeFocused }, prompt: Text("Lock Screen Passcode"))
                .textContentType(.oneTimeCode)
                .keyboardType(type == .alphanumeric ? .asciiCapable : .asciiCapableNumberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isPasscodeFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let problem = type.problem(for: passcode), !passcode.isEmpty {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 4)
        .id(type)
    }

    private func save() {
        guard let passcodeType, passcodeType.problem(for: passcode) == nil else { return }
        settings.passcodeType = passcodeType
        settings.passcode = passcode
        settings.isEnabled = true
        settings.isSetUp = true
    }
}

private struct PasscodeTypeCard: View {
    let type: PasscodeType
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                PasscodeIllustration(type: type)
                    .frame(width: 56, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    type.title
                        .font(.subheadline.weight(.semibold))
                    type.subtitle
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 480)
    }
}

private struct PasscodeIllustration: View {
    let type: PasscodeType

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 64
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(roundedRect: CGRect(x: 1, y: 1, width: 62, height: 70), cornerRadius: 8), with: .color(Color(.systemBackground)))
            context.stroke(Path(roundedRect: CGRect(x: 1, y: 1, width: 62, height: 70), cornerRadius: 8), with: .color(Color(.systemGray4)), lineWidth: 1)
            let key = Color(.systemFill)
            switch type {
            case .pin:
                for index in 0..<6 {
                    context.fill(Path(ellipseIn: CGRect(x: 15 + CGFloat(index) * 6, y: 12, width: 4.4, height: 4.4)), with: .color(.primary))
                }
                keypad(context, top: 29, key: key)
            case .numeric:
                context.fill(Path(roundedRect: CGRect(x: 10, y: 9, width: 44, height: 10), cornerRadius: 5), with: .color(key))
                keypad(context, top: 31, key: key)
            case .alphanumeric:
                context.fill(Path(roundedRect: CGRect(x: 10, y: 12, width: 44, height: 10), cornerRadius: 5), with: .color(key))
                for (index, inset) in [6, 8, 12].enumerated() {
                    context.fill(Path(roundedRect: CGRect(x: CGFloat(inset), y: 36 + CGFloat(index) * 10, width: 64 - CGFloat(inset) * 2, height: 8), cornerRadius: 2), with: .color(key))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func keypad(_ context: GraphicsContext, top: CGFloat, key: Color) {
        for row in 0..<3 {
            for column in 0..<3 {
                let center = CGPoint(x: 20 + CGFloat(column) * 12, y: top + CGFloat(row) * 13)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)), with: .color(key))
            }
        }
    }
}
