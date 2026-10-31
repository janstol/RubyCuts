import Foundation

/// Watches the iCloud container's `Documents` folder for `.rb` changes with an
/// `NSMetadataQuery`, and calls back so ``ScriptLibrary`` can re-list.
///
/// The query is a change trigger, not the source of truth: the library still
/// reads the folder through ``ScriptStore/list()``. The query is what notices
/// that another device (or another editor, through Finder or Files) changed
/// something, which a plain directory listing can't.
///
/// It also starts downloading every result that isn't current on this
/// device, so changes from other devices arrive without the user having to
/// open each script first.
///
/// Only used in iCloud mode. `@MainActor` because `NSMetadataQuery` delivers
/// its notifications on the thread that started it, which here is the main
/// thread.
@MainActor
final class ScriptSyncMonitor {
    /// Called after the first gathering and after every update.
    private let onChange: () -> Void

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    /// The number of `.rb` items the first gathering found, once it has
    /// finished. `nil` before that.
    private(set) var initialScriptCount: Int?

    /// Callers of ``waitForInitialGathering(timeout:)`` still waiting.
    private var gatheringWaiters: [CheckedContinuation<Int?, Never>] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Starts the query. Call once.
    func start() {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.rb")
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleResults(isInitialGathering: true) }
            },
            center.addObserver(
                forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleResults(isInitialGathering: false) }
            },
        ]
        query.start()
    }

    /// Stops the query and releases anyone still waiting on the first
    /// gathering with `nil`.
    func stop() {
        query.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        finishWaiting(with: nil)
    }

    /// Waits for the first gathering and returns how many `.rb` items it
    /// found, or `nil` if it didn't finish within `timeout` (or the monitor
    /// was stopped).
    func waitForInitialGathering(timeout: Duration) async -> Int? {
        if let initialScriptCount {
            return initialScriptCount
        }
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishWaiting(with: nil)
        }
        return await withCheckedContinuation { continuation in
            gatheringWaiters.append(continuation)
        }
    }

    private func handleResults(isInitialGathering: Bool) {
        query.disableUpdates()
        let items = query.results.compactMap { $0 as? NSMetadataItem }
        for item in items {
            let status =
                item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            guard status != NSMetadataUbiquitousItemDownloadingStatusCurrent,
                let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
            else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        query.enableUpdates()

        if isInitialGathering {
            initialScriptCount = items.count
            finishWaiting(with: items.count)
        }
        onChange()
    }

    private func finishWaiting(with count: Int?) {
        let waiters = gatheringWaiters
        gatheringWaiters = []
        for waiter in waiters {
            waiter.resume(returning: count)
        }
    }
}
