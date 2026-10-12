import Foundation

/// The user's shortcuts. Only commands the user changed are saved; every other command uses its
/// default, so new commands added by an update get their default keys without touching custom ones.
@MainActor
final class ShortcutStore: ObservableObject {
    private static let key = "shortcuts.v1"

    @Published private(set) var custom: [String: [KeyBinding]] = [:]
    /// Called after any change, to re-register the global hotkeys.
    var onChange: (() -> Void)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: [KeyBinding]].self, from: data) {
            custom = saved
        }
    }

    func bindings(for command: Command) -> [KeyBinding] {
        custom[command.id] ?? command.defaultBindings
    }

    func isCustomized(_ command: Command) -> Bool { custom[command.id] != nil }

    var hasCustomizations: Bool { !custom.isEmpty }

    func add(_ binding: KeyBinding, to command: Command) {
        // A key combination drives one command only: take it away from any other command.
        for other in Command.all where other != command && bindings(for: other).contains(binding) {
            set(bindings(for: other).filter { $0 != binding }, for: other, notify: false)
        }
        var list = bindings(for: command)
        if !list.contains(binding) { list.append(binding) }
        set(list, for: command)
    }

    func remove(_ binding: KeyBinding, from command: Command) {
        set(bindings(for: command).filter { $0 != binding }, for: command)
    }

    func reset(_ command: Command) {
        custom.removeValue(forKey: command.id)
        save()
    }

    func resetAll() {
        custom.removeAll()
        save()
    }

    /// The command that already uses `binding`, if any.
    func command(using binding: KeyBinding) -> Command? {
        Command.all.first { bindings(for: $0).contains(binding) }
    }

    private func set(_ list: [KeyBinding], for command: Command, notify: Bool = true) {
        custom[command.id] = list == command.defaultBindings ? nil : list
        if notify { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        onChange?()
    }
}
