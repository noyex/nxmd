import AppKit
import CoreText

enum Theme {
    static let background = NSColor.black
    static let foreground = NSColor(white: 0.93, alpha: 1)
    static let muted = NSColor(white: 0.54, alpha: 1)
    static let hover = NSColor(white: 0.15, alpha: 1)
    static let border = NSColor(white: 0.17, alpha: 1)
    static let dockFill = NSColor(white: 0.085, alpha: 0.92)

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts") else { return }
        for name in ["Geist-Variable", "GeistMono-Variable"] {
            let url = dir.appendingPathComponent("\(name).ttf")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func sans(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(family: "Geist", size: size, weight: weight)
            ?? .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(family: "Geist Mono", size: size, weight: weight)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size),
              font.familyName == family else { return nil }
        return font
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The app that "Edit" opens the file in: a code editor if one is installed.
enum ExternalEditor {
    private static let candidates = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "dev.zed.Zed",
        "com.sublimetext.4",
        "com.apple.TextEdit",
    ]

    static var app: (url: URL, name: String)? {
        for id in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let name = FileManager.default.displayName(atPath: url.path)
                return (url, name.replacingOccurrences(of: ".app", with: ""))
            }
        }
        return nil
    }

    static func open(_ file: URL) {
        guard let app else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: app.url,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
