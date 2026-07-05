import Foundation

/// Watches a single file for external modification and fires `onChange`.
///
/// Handles editors that save atomically (write to a temp file, then rename over
/// the original): on a delete/rename the underlying descriptor is stale, so we
/// re-arm on the path before notifying. Events are debounced to coalesce the
/// burst a single save produces. [REF:fr:live-reload]
final class FileWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.markio.filewatcher")
    private let debounce: DispatchTimeInterval

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var pending: DispatchWorkItem?

    init(
        url: URL,
        debounce: DispatchTimeInterval = .milliseconds(80),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() { queue.async { [self] in arm() } }

    func stop() { queue.async { [self] in disarm() } }

    deinit { source?.cancel() }

    // MARK: - Queue-confined internals

    private func arm() {
        disarm()
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // File may be mid-replace; retry shortly so atomic saves re-attach.
            queue.asyncAfter(deadline: .now() + 0.1) { [self] in arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: queue
        )
        src.setEventHandler { [self] in
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                    arm()
                    notify()
                }
            } else {
                notify()
            }
        }
        let fd = fileDescriptor
        src.setCancelHandler { if fd >= 0 { close(fd) } }
        source = src
        src.resume()
    }

    private func notify() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func disarm() {
        pending?.cancel()
        pending = nil
        source?.cancel()  // cancel handler closes the descriptor
        source = nil
        fileDescriptor = -1
    }
}
