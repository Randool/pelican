import Cocoa
import ServiceManagement

/// The menu bar handle: show/hide, three sizes, launch at login, quit.
/// It reads the live window width so a corner drag ticks the right size.
final class StatusMenu: NSObject, NSMenuDelegate {
    /// The widths offered in the menu; a corner drag can land between them.
    static let widths: [(title: String, width: CGFloat)] = [("小", 480), ("中", 680), ("大", 900)]

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var sizeItems: [NSMenuItem] = []
    private var loginItem: NSMenuItem!
    private let onToggle: () -> Void
    private let onPickWidth: (CGFloat) -> Void
    private let liveWidth: () -> CGFloat

    init(onToggle: @escaping () -> Void,
         onPickWidth: @escaping (CGFloat) -> Void,
         liveWidth: @escaping () -> CGFloat) {
        self.onToggle = onToggle
        self.onPickWidth = onPickWidth
        self.liveWidth = liveWidth
        super.init()
        build()
    }

    /// The tooltip is the only place the current rate shows unopened.
    var tooltip: String? {
        get { statusItem.button?.toolTip }
        set { statusItem.button?.toolTip = newValue }
    }

    private func build() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bicycle", accessibilityDescription: "鹈鹕")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        let toggle = NSMenuItem(title: "显示 / 隐藏 鹈鹕", action: #selector(toggleVisible),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let sizeMenu = NSMenu()
        for (i, s) in Self.widths.enumerated() {
            let h = Int(Scene.height(for: s.width))
            let item = NSMenuItem(title: "\(s.title)（\(Int(s.width))×\(h)）",
                                  action: #selector(pickSize(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            sizeMenu.addItem(item)
            sizeItems.append(item)
        }
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func toggleVisible() { onToggle() }

    @objc private func pickSize(_ sender: NSMenuItem) {
        onPickWidth(Self.widths[sender.tag].width)
    }

    /// The menu switch: the app registers itself, no plist to write by hand.
    private var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("开机自启没切成: \(error.localizedDescription)")
        }
    }

    // Ticks follow the live window: a corner drag changes the width behind us.
    func menuWillOpen(_ menu: NSMenu) {
        let w = liveWidth()
        for (i, item) in sizeItems.enumerated() {
            item.state = abs(w - Self.widths[i].width) < 1 ? .on : .off
        }
        loginItem.state = loginEnabled ? .on : .off
    }
}
