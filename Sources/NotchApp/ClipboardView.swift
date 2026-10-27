import SwiftUI

struct ClipboardView: View {
    @ObservedObject var manager: ClipboardManager
    @State private var copiedItemID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if manager.items.isEmpty {
                Spacer()
                Text("Буфер обмена пуст")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(manager.items) { item in
                            row(for: item)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(for item: ClipboardItem) -> some View {
        ClipboardRow(
            item: item,
            isCopied: copiedItemID == item.id
        ) {
            manager.copyToPasteboard(item)
            copiedItemID = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if copiedItemID == item.id { copiedItemID = nil }
            }
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isCopied: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(item.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                if isCopied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(item.date, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
