import AppKit

struct ClipboardItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

final class ClipboardManager: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let maxItems = 50
    private var isWritingOwnChange = false

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        isWritingOwnChange = true
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        isWritingOwnChange = false

        if let index = items.firstIndex(of: item) {
            items.remove(at: index)
            items.insert(item, at: 0)
        }
    }

    func clear() {
        items.removeAll()
    }

    private func pollPasteboard() {
        guard !isWritingOwnChange else { return }
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if items.first?.text == text { return }

        items.removeAll { $0.text == text }
        items.insert(ClipboardItem(text: text, date: Date()), at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
    }
}
