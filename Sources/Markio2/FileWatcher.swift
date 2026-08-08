import Foundation

/// Watches one file for external modification.
///
/// A vnode source rather than FSEvents: it is one file descriptor and no
/// directory traffic. Editors that save atomically replace the file rather than
/// writing it in place, which delivers `.rename`/`.delete` and invalidates the
/// descriptor — so the owner re-arms the watch after every reload rather than
/// assuming this object survives the save.
final class FileWatcher {
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        // Editors write in bursts; coalescing avoids re-parsing a large file
        // several times for one save.
        let pending = PendingReload(onChange: onChange)
        source.setEventHandler { pending.schedule() }
        let closing = descriptor
        source.setCancelHandler { close(closing) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Debounces a burst of file-system events into one reload.
private final class PendingReload: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.markio.two.watch")
    private var work: DispatchWorkItem?

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func schedule() {
        queue.async { [self] in
            work?.cancel()
            let item = DispatchWorkItem { [onChange] in onChange() }
            work = item
            queue.asyncAfter(deadline: .now() + 0.12, execute: item)
        }
    }
}
