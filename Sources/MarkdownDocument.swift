import AppKit

/// A read-only Markdown file. Watches the file on disk and re-renders on change.
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    private(set) var text = ""
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    /// The tab showing this file. Documents live as tabs in a shared window,
    /// so they have no window controllers of their own.
    weak var tab: DocumentTab?

    override class var autosavesInPlace: Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        update(text: String(decoding: data, as: UTF8.self))
    }

    override func makeWindowControllers() {
        ViewerWindowController.forNewDocument().addTab(for: self)
        startWatching()
    }

    override func showWindows() {
        if let tab { tab.host?.show(tab) }
    }

    override var windowForSheet: NSWindow? {
        tab?.host?.window ?? super.windowForSheet
    }

    override func close() {
        stopWatching()
        super.close()
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let tab else { throw CocoaError(.featureUnsupported) }
        return tab.printOperation(printInfo: printInfo)
    }

    override func presentedItemDidMove(to newURL: URL) {
        super.presentedItemDidMove(to: newURL)
        DispatchQueue.main.async { [weak self] in
            self?.startWatching()
            self?.tab?.render()
        }
    }

    private func update(text newText: String) {
        guard newText != text else { return }
        text = newText
        tab?.render()
    }

    // MARK: - Live reload

    private func startWatching(attempt: Int = 0) {
        stopWatching()
        guard let url = fileURL else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Editors that save atomically briefly remove the file. Retry for ~2 s.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.startWatching(attempt: attempt + 1)
                }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // The file was replaced; watch the new one at the same path.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.startWatching()
                }
            }
            self.scheduleReload()
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.fileURL,
                  let data = try? Data(contentsOf: url) else { return }
            self.update(text: String(decoding: data, as: UTF8.self))
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
