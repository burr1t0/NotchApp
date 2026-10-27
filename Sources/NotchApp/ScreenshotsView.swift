import SwiftUI
import UniformTypeIdentifiers

/// Screenshots and files in one place: drop a file on the panel (or copy one
/// in Finder) to park it here, then drag it back out where it's needed.
struct ScreenshotsView: View {
    @ObservedObject var watcher: ScreenshotWatcher
    @State private var isDropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 64), spacing: 8)]

    var body: some View {
        Group {
            if watcher.items.isEmpty && watcher.files.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 16))
                    Text("Скриншоты и файлы")
                        .font(.system(size: 11, weight: .medium))
                    Text("Перетащите файл сюда или скопируйте его в Finder")
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(watcher.files) { file in
                            FileTile(file: file, watcher: watcher)
                        }
                        ForEach(watcher.items) { item in
                            ScreenshotThumbnail(item: item, watcher: watcher)
                        }
                    }
                    .padding(4)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(isDropTargeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { watcher.addFiles([url]) }
                }
            }
            return true
        }
    }
}

private struct FileTile: View {
    let file: ShelfFile
    let watcher: ScreenshotWatcher
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: file.icon)
                .resizable()
                .frame(width: 34, height: 34)
            Text(file.name)
                .font(.system(size: 8.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(width: 64, height: 64)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.16 : 0.08))
        )
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button { watcher.remove(file) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { watcher.open(file) }
        .onHover { isHovering = $0 }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .help(file.url.path)
        .contextMenu {
            Button("Открыть") { watcher.open(file) }
            Button("Показать в Finder") { watcher.reveal(file) }
            Button("Убрать с полки") { watcher.remove(file) }
        }
    }
}

private struct ScreenshotThumbnail: View {
    let item: ScreenshotItem
    let watcher: ScreenshotWatcher
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        Image(nsImage: item.thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(isHovering ? 0.5 : 0), lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                if didCopy {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                watcher.open(item)
                if !item.isFile {
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { didCopy = false }
                }
            }
            .onHover { isHovering = $0 }
            .onDrag {
                switch item.origin {
                case .file(let url): return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                case .clipboardImage(let image): return NSItemProvider(object: image)
                }
            }
            .contextMenu {
                if item.isFile {
                    Button("Показать в Finder") { watcher.reveal(item) }
                    Button("Открыть") { watcher.open(item) }
                } else {
                    Button("Скопировать") { watcher.open(item) }
                    Button("Сохранить как…") { watcher.save(item) }
                }
            }
    }
}
