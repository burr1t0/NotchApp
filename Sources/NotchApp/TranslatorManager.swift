import Foundation

enum TranslatorSide { case ru, en }

/// Owned by NotchWindowController (not the view) so the last translation
/// survives the panel collapsing — TranslatorView itself gets torn down and
/// recreated every time the panel hides (it's behind an `if` in ContentView),
/// which would otherwise reset any @State back to empty each time.
final class TranslatorManager: ObservableObject {
    @Published var ruText: String = ""
    @Published var enText: String = ""
    /// Which side holds the most recent translation *result* — used by the
    /// copy button, independent of whatever currently has keyboard focus.
    @Published var lastTranslatedSide: TranslatorSide?

    func reset() {
        ruText = ""
        enText = ""
        lastTranslatedSide = nil
    }
}
