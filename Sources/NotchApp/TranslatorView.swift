import SwiftUI
import Translation
import NaturalLanguage
import AppKit

private let ru = Locale.Language(identifier: "ru")
private let en = Locale.Language(identifier: "en")

struct TranslatorView: View {
    @ObservedObject var manager: TranslatorManager

    /// Which box is actually focused right now. Translation only ever
    /// listens to text changes on the focused side — a result written into
    /// the *other* box is a programmatic update, not a user edit, so it
    /// must never itself trigger a reverse translation. This also means
    /// typing keeps going uninterrupted until the user deliberately clicks
    /// into the other box themselves.
    @FocusState private var focusedSide: TranslatorSide?

    @State private var configuration: TranslationSession.Configuration?
    @State private var isTranslating = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var didCopy = false
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            languageColumn(label: "RU", text: $manager.ruText, side: .ru)

            centerControls

            languageColumn(label: "EN", text: $manager.enText, side: .en)
        }
        .translationTask(configuration) { session in
            await performTranslation(using: session)
        }
        // Focus starts out nil each time the panel reopens (TranslatorView
        // is recreated), but the window itself only becomes key on demand
        // (see NotchWindowController) — grab focus proactively so the very
        // first click into a box both focuses AND places the cursor,
        // instead of the first click just waking the window up.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusedSide = .ru
            }
            installCopyShortcut()
        }
        .onDisappear {
            removeCopyShortcut()
        }
    }

    /// Our panel deliberately never *activates* the app (see NotchPanel) —
    /// it only becomes key. But Cmd+C/Cmd+V are normally routed through the
    /// active application's main menu key-equivalents, which we don't
    /// have, so the system never delivers them to our text field at all.
    /// Intercepting them directly and re-dispatching as plain responder-
    /// chain actions (bypassing the menu entirely) is what actually makes
    /// them reach the focused NSTextView.
    ///
    /// Matched by physical `keyCode` rather than the event's characters —
    /// with a Cyrillic (or any non-Latin) input source active, the "C" key
    /// reports its Cyrillic character (е.g. "с"), not Latin "c", so a
    /// characters-based comparison silently never matches.
    private func installCopyShortcut() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            switch event.keyCode {
            case 8 where flags == .command: // kVK_ANSI_C
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                return nil
            case 9 where flags == .command: // kVK_ANSI_V
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                return nil
            case 7 where flags == .command: // kVK_ANSI_X
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                return nil
            case 0 where flags == .command: // kVK_ANSI_A
                NSApp.sendAction(#selector(NSStandardKeyBindingResponding.selectAll(_:)), to: nil, from: nil)
                return nil
            case 6 where flags == .command: // kVK_ANSI_Z — undo
                NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                return nil
            case 6 where flags == [.command, .shift]: // Cmd+Shift+Z — redo
                NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                return nil
            default:
                return event
            }
        }
    }

    private func removeCopyShortcut() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private var centerControls: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.25))

            Button {
                manager.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Очистить")

            Button {
                copyTranslation()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(didCopy ? .green : .white.opacity(0.5))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(manager.lastTranslatedSide == nil)
            .help("Скопировать перевод")

            Spacer(minLength: 0)
        }
    }

    private func languageColumn(label: String, text: Binding<String>, side: TranslatorSide) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                if focusedSide == side && isTranslating {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            TextEditor(text: text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(.white.opacity(0.9))
                .focused($focusedSide, equals: side)
                .onChange(of: text.wrappedValue) { _, _ in
                    guard focusedSide == side else { return }
                    scheduleAutoTranslate(from: side)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyTranslation() {
        guard let side = manager.lastTranslatedSide else { return }
        let text = side == .ru ? manager.ruText : manager.enText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { didCopy = false }
    }

    private func scheduleAutoTranslate(from side: TranslatorSide) {
        debounceTask?.cancel()

        let sourceText = side == .ru ? manager.ruText : manager.enText
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if side == .ru { manager.enText = "" } else { manager.ruText = "" }
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { translate(from: side) }
        }
    }

    private func detectedSourceLanguage(for text: String) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.russian, .english]
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage {
            return Locale.Language(identifier: language.rawValue)
        }
        let hasCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return Locale.Language(identifier: hasCyrillic ? "ru" : "en")
    }

    private func translate(from side: TranslatorSide) {
        let sourceText = side == .ru ? manager.ruText : manager.enText
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isTranslating = true
        let source = side == .ru ? ru : en
        let target = side == .ru ? en : ru

        if configuration == nil {
            configuration = TranslationSession.Configuration(source: source, target: target)
        } else {
            configuration?.source = source
            configuration?.target = target
            configuration?.invalidate()
        }
    }

    private func performTranslation(using session: TranslationSession) async {
        defer { isTranslating = false }
        // Derive direction from the session itself, not current focus —
        // focus may have moved on by the time this completes.
        let side: TranslatorSide = session.sourceLanguage?.languageCode == ru.languageCode ? .ru : .en
        let sourceText = side == .ru ? manager.ruText : manager.enText
        do {
            // Code identifiers are expanded to spaced phrases for the translator
            // only; the text in the input box stays exactly as typed.
            let response = try await session.translate(IdentifierSplitter.expand(sourceText))
            let targetSide: TranslatorSide = side == .ru ? .en : .ru
            if side == .ru {
                manager.enText = response.targetText
            } else {
                manager.ruText = response.targetText
            }
            manager.lastTranslatedSide = targetSide
        } catch {
            // Leave the other side untouched rather than showing an error
            // inline in someone else's translated text.
        }
    }
}
