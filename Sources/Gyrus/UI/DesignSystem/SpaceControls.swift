import SwiftUI

enum SpaceTheme {
    static let accent = Color(red: 0.459, green: 0.424, blue: 1)
    static let surface = Color(red: 0.045, green: 0.045, blue: 0.065)
}

struct SpaceButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.35))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(prominent ? SpaceTheme.accent.opacity(isEnabled ? 0.85 : 0.2)
                        : .white.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(configuration.isPressed ? 0.28 : 0.14)))
            .contentShape(Capsule())
    }
}

struct SpaceField: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 15))
            .padding(14)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18)))
    }
}

struct TopicSearchActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var topicSearchAction: (() -> Void)? {
        get { self[TopicSearchActionKey.self] }
        set { self[TopicSearchActionKey.self] = newValue }
    }
}

struct TopicSearchCommands: Commands {
    @FocusedValue(\.topicSearchAction) private var find
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find Topic") { find?() }
                .keyboardShortcut("f", modifiers: .control)
                .disabled(find == nil)
        }
    }
}
