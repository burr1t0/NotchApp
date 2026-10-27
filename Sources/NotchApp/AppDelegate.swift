import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerAsLoginItem()
        notchController = NotchWindowController()
        notchController?.show()
    }

    private func registerAsLoginItem() {
        guard SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }
}
