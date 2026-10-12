import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Captures the next key combination typed in the Settings window.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var recording: Command?
    @Published var message: String?
    /// Global hotkeys are suspended while recording so the keys reach the recorder.
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?

    func start(for command: Command, store: ShortcutStore) {
        cancel()
        recording = command
        message = nil
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, command: command, store: store) }
            return nil
        }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil {
            recording = nil
            onRecordingChange?(false)
        }
    }

    private func handle(_ event: NSEvent, command: Command, store: ShortcutStore) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let code = Int(event.keyCode)
        if code == kVK_Escape && modifiers.isEmpty {
            cancel()
            return
        }
        let isFunctionKey = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                             kVK_F10, kVK_F11, kVK_F12].contains(code)
        guard isFunctionKey || !modifiers.intersection([.control, .option, .command]).isEmpty else {
            message = L("A shortcut needs at least one of Control, Option or Command.")
            NSSound.beep()
            return
        }
        let binding = KeyBinding(keyCode: UInt32(code), modifiers: modifiers)
        if let previous = store.command(using: binding), previous != command {
            message = L("%@ now runs this instead of “%@”.", binding.display, previous.title)
        }
        store.add(binding, to: command)
        cancel()
    }
}

struct ShortcutsSettings: View {
    @EnvironmentObject private var store: ShortcutStore
    @EnvironmentObject private var recorder: ShortcutRecorder

    var body: some View {
        Form {
            Section {
                ForEach(Command.all, id: \.id) { command in
                    ShortcutRow(command: command)
                }
            } header: {
                Text(L("Shortcuts"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = recorder.message {
                        Text(message).foregroundStyle(.orange)
                    }
                    Text(L("Shortcuts follow the keys' position on the keyboard; the character shown matches the selected layout (AZERTY, QWERTZ, Dvorak, Turkish…). A command can have several shortcuts."))
                        .foregroundStyle(.secondary)
                    Button(L("Restore All Defaults")) { store.resetAll() }
                        .disabled(!store.hasCustomizations)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.cancel() }
    }
}

private struct ShortcutRow: View {
    @EnvironmentObject private var store: ShortcutStore
    @EnvironmentObject private var recorder: ShortcutRecorder
    let command: Command

    var body: some View {
        HStack(spacing: 6) {
            Text(command.title)
                .lineLimit(1)
                .help(command.id)
            Spacer(minLength: 8)
            ForEach(store.bindings(for: command), id: \.self) { binding in
                HStack(spacing: 3) {
                    Text(binding.display).font(.system(size: 12, design: .rounded)).monospacedDigit()
                    Button { store.remove(binding, from: command) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Remove this shortcut"))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                .help(binding.spokenDisplay)
            }
            if recorder.recording == command {
                Text(L("Type the keys… (Esc to cancel)"))
                    .font(.system(size: 12))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor))
            } else {
                Button { recorder.start(for: command, store: store) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help(L("Record a new shortcut"))
            }
            if store.isCustomized(command) {
                Button { store.reset(command) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help(L("Back to the default shortcut"))
            }
        }
    }
}
