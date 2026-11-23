import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFiles = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a file (from Dock or Spotlight): ask for one.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.openedFiles, NSDocumentController.shared.documents.isEmpty else { return }
            NSDocumentController.shared.openDocument(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFiles = true
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        main.addSubmenu("nxmd") { menu in
            menu.addItem("About nxmd", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            menu.addItem(.separator())
            menu.addItem("Hide nxmd", #selector(NSApplication.hide(_:)), "h")
            menu.addItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            menu.addItem("Show All", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            menu.addItem("Quit nxmd", #selector(NSApplication.terminate(_:)), "q")
        }

        main.addSubmenu("File") { menu in
            menu.addItem("Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            let recent = NSMenu(title: "Open Recent")
            recent.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
            recent.addItem("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
            let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            recentItem.submenu = recent
            menu.addItem(recentItem)
            menu.addItem(.separator())
            menu.addItem("Close", #selector(NSWindow.performClose(_:)), "w")
            menu.addItem(.separator())
            menu.addItem("Print…", #selector(NSDocument.printDocument(_:)), "p")
        }

        main.addSubmenu("Edit") { menu in
            menu.addItem("Copy", #selector(NSText.copy(_:)), "c")
            menu.addItem("Select All", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(.separator())
            menu.addItem("Find…", #selector(ViewerWindowController.showFindBar(_:)), "f")
            menu.addItem("Find Next", #selector(ViewerWindowController.findNext(_:)), "g")
            menu.addItem("Find Previous", #selector(ViewerWindowController.findPrevious(_:)), "g", [.command, .shift])
        }

        main.addSubmenu("View") { menu in
            menu.addItem("Actual Size", #selector(ViewerWindowController.resetZoom(_:)), "0")
            menu.addItem("Zoom In", #selector(ViewerWindowController.zoomIn(_:)), "+")
            let zoomInAlt = menu.addItem("Zoom In", #selector(ViewerWindowController.zoomIn(_:)), "=")
            zoomInAlt.isHidden = true
            zoomInAlt.allowsKeyEquivalentWhenHidden = true
            menu.addItem("Zoom Out", #selector(ViewerWindowController.zoomOut(_:)), "-")
            menu.addItem(.separator())
            menu.addItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        let window = main.addSubmenu("Window") { menu in
            menu.addItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            menu.addItem("Zoom", #selector(NSWindow.performZoom(_:)))
            menu.addItem(.separator())
            menu.addItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        }
        NSApp.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    @discardableResult
    func addSubmenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
        let submenu = NSMenu(title: title)
        build(submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
        return submenu
    }

    @discardableResult
    func addItem(_ title: String, _ action: Selector?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        addItem(item)
        return item
    }
}
