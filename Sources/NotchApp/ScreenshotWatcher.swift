import AppKit
import ImageIO

struct ScreenshotItem: Identifiable {
    enum Origin {
        case file(URL)
        case clipboardImage(NSImage)
    }

    let id: String
    let origin: Origin
    let modified: Date
    let thumbnail: NSImage

    var isFile: Bool {
        if case .file = origin { return true }
        return false
    }
}

/// A file parked on the shelf, by reference (nothing is copied).
struct ShelfFile: Identifiable {
    let url: URL
    let added: Date
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

/// Screenshots on this Mac may be configured to save as files (Desktop,
/// Downloads, a custom folder) or to go straight to the clipboard
/// (`defaults read com.apple.screencapture` → target=clipboard, which is
/// this user's setup). We watch both paths at once so the tab works either
/// way.
final class ScreenshotWatcher: ObservableObject {
    @Published private(set) var items: [ScreenshotItem] = []
    /// Files dropped on the notch or copied in Finder.
    @Published private(set) var files: [ShelfFile] = []

    private let maxItems = 15
    private let thumbnailSize: CGFloat = 200

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private let watchedDirectory: URL?

    private var clipboardTimer: Timer?
    private let pasteboard = NSPasteboard.general
    private var lastClipboardChangeCount: Int

    private var fileItems: [ScreenshotItem] = []
    private var clipboardItems: [ScreenshotItem] = []

    init() {
        // Only watch a folder when screenshots actually save to disk —
        // when `target=clipboard`, there's no dedicated screenshot folder
        // at all, and watching "last used save folder" (a stale default,
        // often Downloads) just vacuums up unrelated downloaded images.
        watchedDirectory = ScreenshotWatcher.screenSavesToDisk() ? ScreenshotWatcher.resolveScreenshotDirectory() : nil
        lastClipboardChangeCount = NSPasteboard.general.changeCount
    }

    /// Fills the shelf with sample entries for recording the demo animation.
    func applyDemo(items: [ScreenshotItem], files: [ShelfFile]) {
        self.items = items
        self.files = files
    }

    func start() {
        if let watchedDirectory {
            rescanDirectory(watchedDirectory)

            directoryFD = Darwin.open(watchedDirectory.path, O_EVTONLY)
            if directoryFD >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: directoryFD,
                    eventMask: [.write],
                    queue: .main
                )
                source.setEventHandler { [weak self] in
                    self?.rescanDirectory(watchedDirectory)
                }
                source.setCancelHandler { [weak self] in
                    if let fd = self?.directoryFD, fd >= 0 {
                        close(fd)
                    }
                }
                source.resume()
                directorySource = source
            }
        }

        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
    }

    func stop() {
        directorySource?.cancel()
        directorySource = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
    }

    func addFiles(_ urls: [URL]) {
        let fresh = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !fresh.isEmpty else { return }
        var updated = files.filter { existing in !fresh.contains { $0.path == existing.url.path } }
        updated.insert(contentsOf: fresh.map { ShelfFile(url: $0, added: Date()) }, at: 0)
        files = Array(updated.prefix(maxItems))
    }

    func remove(_ file: ShelfFile) {
        files.removeAll { $0.id == file.id }
    }

    func open(_ file: ShelfFile) {
        NSWorkspace.shared.open(file.url)
    }

    func reveal(_ file: ShelfFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func reveal(_ item: ScreenshotItem) {
        if case .file(let url) = item.origin {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func open(_ item: ScreenshotItem) {
        switch item.origin {
        case .file(let url):
            NSWorkspace.shared.open(url)
        case .clipboardImage(let image):
            copyToPasteboard(image)
        }
    }

    func copyToPasteboard(_ image: NSImage) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        lastClipboardChangeCount = pasteboard.changeCount
    }

    func save(_ item: ScreenshotItem) {
        guard case .clipboardImage(let image) = item.origin,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Screenshot.png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    // MARK: - File-based screenshots

    private static func screenSavesToDisk() -> Bool {
        readDefaultsDomain()["target"] as? String != "clipboard"
    }

    private static func resolveScreenshotDirectory() -> URL {
        let defaultsDomain = readDefaultsDomain()

        for key in ["location", "location-last"] {
            if let path = defaultsDomain[key] as? String, !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                    return URL(fileURLWithPath: expanded)
                }
            }
        }

        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private static func readDefaultsDomain() -> [String: Any] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.screencapture"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        guard (try? task.run()) != nil else { return [:] }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: Any] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            result[key] = value
        }
        return result
    }

    private func rescanDirectory(_ watchedDirectory: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: watchedDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
        let candidates = entries.filter { imageExtensions.contains($0.pathExtension.lowercased()) }

        let existingByID = Dictionary(uniqueKeysWithValues: fileItems.map { ($0.id, $0) })

        var updated: [(URL, Date)] = []
        for url in candidates {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            updated.append((url, modified))
        }
        updated.sort { $0.1 > $1.1 }

        var newFileItems: [ScreenshotItem] = []
        for (url, modified) in updated.prefix(maxItems) {
            let id = url.path
            if let existing = existingByID[id], existing.modified == modified {
                newFileItems.append(existing)
            } else if let thumbnail = ScreenshotWatcher.makeThumbnail(for: url, maxPixelSize: thumbnailSize) {
                newFileItems.append(ScreenshotItem(id: id, origin: .file(url), modified: modified, thumbnail: thumbnail))
            }
        }

        fileItems = newFileItems
        mergeAndPublish()
    }

    private static func makeThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Clipboard-based screenshots

    private func pollClipboard() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = currentChangeCount

        // Files copied in Finder go on the shelf.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addFiles(urls)
            return
        }

        // A screenshot-to-clipboard capture is raw image bytes only.
        // Copying an image *file* in Finder additionally puts a file URL
        // on the pasteboard — that's how we tell the two apart.
        guard pasteboard.string(forType: .string) == nil,
              pasteboard.types?.contains(.fileURL) != true,
              let image = NSImage(pasteboard: pasteboard) else { return }

        let item = ScreenshotItem(
            id: UUID().uuidString,
            origin: .clipboardImage(image),
            modified: Date(),
            thumbnail: image
        )
        clipboardItems.insert(item, at: 0)
        if clipboardItems.count > maxItems {
            clipboardItems.removeLast(clipboardItems.count - maxItems)
        }
        mergeAndPublish()
    }

    private func mergeAndPublish() {
        items = (fileItems + clipboardItems)
            .sorted { $0.modified > $1.modified }
            .prefix(maxItems)
            .map { $0 }
    }
}
