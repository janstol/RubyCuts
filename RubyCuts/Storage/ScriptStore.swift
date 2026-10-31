import Foundation

/// An error raised while managing scripts through ``ScriptStore``.
enum ScriptStoreError: Error {
    /// The name passed to ``ScriptStore/create(name:source:)`` or ``ScriptStore/rename(_:to:)`` was empty or only whitespace after sanitization.
    case invalidName

    /// The URL doesn't point at a regular file: a directory that happens to
    /// end in `.rb`, a symlink, or something that's gone. ``ScriptStore``
    /// refuses to delete or rename it as a script, so the ordinary delete
    /// path can never remove a whole directory.
    case notAScript

    /// The script is in iCloud but only as a placeholder, so it can't be
    /// renamed or deleted yet. A download has been started; opening the
    /// script waits for it.
    case notDownloaded

    /// ``ScriptStore/loadSource(of:timeout:)`` gave up waiting for iCloud to
    /// download the script.
    case downloadTimedOut
}

extension ScriptStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "The script name can't be empty."
        case .notAScript:
            return
                "That item isn't a script file (it may be a folder or a link), so it was left alone."
        case .notDownloaded:
            return "This script hasn't downloaded from iCloud yet. Open it once, then try again."
        case .downloadTimedOut:
            return
                "The script didn't finish downloading from iCloud. Check your connection and try again."
        }
    }
}

/// A value-type store over a directory of `.rb` files, the backing layer for
/// the script list and the "Run Ruby Script" App Intent. No SwiftData: scripts
/// are plain `.rb` files, so the filesystem *is* the database, and this
/// type is a thin set of operations over one directory URL.
///
/// `Sendable` because the only stored state is a `let directoryURL`; the
/// filesystem is the mutable backing store, so there's no in-process state to
/// guard.
///
/// **Local and iCloud:** the same store works over the local Documents folder
/// (``local``) and over the iCloud container's `Documents` folder; which one
/// the app uses is ``ScriptStorage``'s decision. Every write goes through
/// `NSFileCoordinator`, which iCloud requires and which is harmless on local
/// files, so both locations share one code path and one set of tests.
/// ``list()`` stays the source of truth for what's on disk;
/// ``ScriptSyncMonitor``'s metadata query only tells the library when to
/// call it again.
///
/// **Known follow-up:** the synchronous I/O methods here run on whatever
/// actor calls them. File reads and writes for small scripts are fast, so
/// this is fine. ``loadSource(of:timeout:)`` is the exception: it can wait
/// on an iCloud download, so it runs off the caller's actor.
///
/// Like ``Script``, every member is `nonisolated` to opt out of the app target's
/// MainActor-by-default isolation: the store holds no actor-coupled state (only
/// a `let directoryURL`), so it's usable from any context.
struct ScriptStore: Sendable {
    /// The directory this store reads and writes. Stable for the life of the
    /// store; the filesystem is the backing store.
    nonisolated let directoryURL: URL

    /// The app's local script store: the sandbox Documents directory. Used
    /// when iCloud isn't available, and as the source ``ScriptStorage`` moves
    /// scripts out of once it is.
    nonisolated static var local: ScriptStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ScriptStore(directoryURL: documents)
    }

    /// Creates the backing directory if it doesn't exist. Idempotent: a no-op
    /// when the directory is already there.
    nonisolated func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Lists every `.rb` file directly in the backing directory as a ``Script``,
    /// sorted by display name. Only regular files count: non-`.rb` files,
    /// subdirectories (even one named `archive.rb`), and symlinks are skipped.
    /// Symlinks are skipped on purpose, not just because they're rare: one
    /// could point outside this directory, or at a directory, and saving
    /// through it would write wherever it points. URL resource values
    /// describe the link itself, not its target, so `isRegularFile` is
    /// `false` for every symlink.
    ///
    /// An iCloud item that has been evicted from this device may show up as a
    /// hidden placeholder (`.hello.rb.icloud`) instead of under its real name.
    /// That placeholder lists as `hello.rb` with no ``Script/modifiedAt``, so
    /// the script stays visible and opening it downloads it (see
    /// ``loadSource(of:timeout:)``). Newer OS versions keep evicted files under
    /// their real names, which the ordinary path already covers.
    ///
    /// Uses `contentsOfDirectory` (not a recursive enumerator) because the
    /// store writes top-level files only. Requests `.contentModificationDateKey`
    /// so each ``Script/modifiedAt`` comes from the same scan at no extra
    /// cost; a URL whose date can't be read gets `nil` rather than failing the
    /// whole listing.
    ///
    /// Sort stays by name here; re-sorting by other criteria (e.g. date) is
    /// ``ScriptLibrary``'s job.
    nonisolated func list() throws -> [Script] {
        try ensureDirectory()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: Array(keys)
        )
        var scriptsByURL: [URL: Script] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            if url.pathExtension == "rb" {
                scriptsByURL[url] = Script(url: url, modifiedAt: values?.contentModificationDate)
            } else if let realURL = Self.realURL(forPlaceholder: url), scriptsByURL[realURL] == nil
            {
                scriptsByURL[realURL] = Script(url: realURL)
            }
        }
        return scriptsByURL.values.sorted { $0.name < $1.name }
    }

    /// Writes `source` to a new `.rb` file and returns the ``Script`` for it.
    ///
    /// The name is sanitized: leading/trailing whitespace is trimmed, any path
    /// components are dropped (the caller can't escape the directory), and a
    /// trailing `.rb` the caller passed is stripped so `foo.rb` stores as
    /// `foo.rb`, not `foo.rb.rb`. An empty or whitespace-only name throws
    /// ``ScriptStoreError/invalidName``.
    ///
    /// Collisions are never silently overwritten: if `hello.rb` exists, the
    /// file is written as `hello-2.rb`, then `hello-3.rb`, and so on. The
    /// returned ``Script`` points at the actually written URL, which may differ
    /// from what `name` alone would imply.
    nonisolated func create(name: String, source: String) throws -> Script {
        try ensureDirectory()
        let base = try Self.sanitizedBaseName(name)
        let url = uniqueURL(forBaseName: base)
        try Self.coordinateWriting(at: url, options: .forReplacing) { coordinatedURL in
            try source.write(to: coordinatedURL, atomically: true, encoding: .utf8)
        }
        return Script(url: url)
    }

    /// Reads the script's source straight from disk, without coordination or
    /// download. For tests and previews over local files; the app reads
    /// through ``loadSource(of:timeout:)``.
    nonisolated func source(of script: Script) throws -> String {
        try String(contentsOf: script.url, encoding: .utf8)
    }

    /// Reads the script's source the way the app should: downloads it from
    /// iCloud first if this device only has a placeholder, then reads it
    /// through `NSFileCoordinator`. Works the same on a local file, where the
    /// download step is a no-op.
    ///
    /// Before reading, any unresolved iCloud conflict versions are kept as
    /// sibling scripts (see ``preserveConflicts(of:)``), so the source
    /// returned is always the current version and no edit is lost silently.
    ///
    /// Waits up to `timeout` for a download, then throws
    /// ``ScriptStoreError/downloadTimedOut``. A file that has an older local
    /// copy (downloaded, not current) is read right away rather than waiting,
    /// so an offline device still opens what it has.
    ///
    /// `@concurrent` so the wait and the coordinated read run off the
    /// caller's actor (the editor calls this from the main actor).
    @concurrent
    nonisolated func loadSource(of script: Script, timeout: Duration = .seconds(60)) async throws
        -> String
    {
        try await Self.downloadIfNeeded(script.url, timeout: timeout)
        try preserveConflicts(of: script)
        var source = ""
        try Self.coordinateReading(at: script.url) { coordinatedURL in
            source = try String(contentsOf: coordinatedURL, encoding: .utf8)
        }
        return source
    }

    /// Overwrites the script's file with `source`. Atomic, so a crash mid-write
    /// leaves the previous contents intact.
    nonisolated func write(_ script: Script, source: String) throws {
        try Self.coordinateWriting(at: script.url, options: .forReplacing) { coordinatedURL in
            try source.write(to: coordinatedURL, atomically: true, encoding: .utf8)
        }
    }

    /// Renames `script` to `newName` by moving its file, and returns the
    /// ``Script`` at the new URL. The name is sanitized the same way
    /// ``create(name:source:)`` sanitizes. A no-op (the sanitized name resolves
    /// to the same file) returns the original script. If the target file exists
    /// and is a *different* file, the move throws rather than clobber it.
    /// Throws ``ScriptStoreError/notAScript`` if `script` isn't a regular file
    /// (see ``delete(_:)``).
    nonisolated func rename(_ script: Script, to newName: String) throws -> Script {
        try Self.requireRegularFile(script.url)
        let base = try Self.sanitizedBaseName(newName)
        let target = directoryURL.appending(component: base).appendingPathExtension("rb")
        if target == script.url {
            return script
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: script.url, options: .forMoving,
            writingItemAt: target, options: .forReplacing,
            error: &coordinationError
        ) { source, destination in
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                coordinator.item(at: source, didMoveTo: destination)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError {
            throw error
        }
        return Script(url: target)
    }

    /// Deletes the script's file from disk. Throws
    /// ``ScriptStoreError/notAScript`` instead if the URL isn't a regular
    /// file: `removeItem` deletes a directory recursively, and a symlink
    /// isn't something this store created. Checked at delete time rather than
    /// trusting ``list()``, since the file can change in between (the Files
    /// app, or another device through iCloud).
    nonisolated func delete(_ script: Script) throws {
        try Self.requireRegularFile(script.url)
        try Self.coordinateWriting(at: script.url, options: .forDeleting) { coordinatedURL in
            try FileManager.default.removeItem(at: coordinatedURL)
        }
    }

    // MARK: - iCloud conflicts

    /// Keeps every unresolved iCloud conflict version of `script` as its own
    /// script named `<name> (conflict).rb` (with the usual `-2` suffix on a
    /// clash), then marks the versions resolved and removes them. Returns the
    /// copies it created; empty when there was no conflict, which is always
    /// the case for a local file.
    ///
    /// This is the V1 policy: the current version stays in place and the
    /// others appear in the list for the user to compare and delete. There is
    /// no merge UI.
    @discardableResult
    nonisolated func preserveConflicts(of script: Script) throws -> [Script] {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: script.url),
            !versions.isEmpty
        else { return [] }
        var copies: [Script] = []
        for version in versions {
            let conflictSource = try String(contentsOf: version.url, encoding: .utf8)
            copies.append(try create(name: "\(script.name) (conflict)", source: conflictSource))
        }
        try Self.coordinateWriting(at: script.url, options: []) { coordinatedURL in
            for version in versions {
                version.isResolved = true
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: coordinatedURL)
        }
        return copies
    }

    // MARK: - Coordination and download helpers

    /// Runs `body` inside a coordinated write on `url`, rethrowing either the
    /// coordinator's error or the body's.
    nonisolated private static func coordinateWriting(
        at url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) { coordinatedURL in
            do { try body(coordinatedURL) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError {
            throw error
        }
    }

    /// Runs `body` inside a coordinated read of `url`, rethrowing either the
    /// coordinator's error or the body's.
    nonisolated private static func coordinateReading(at url: URL, _ body: (URL) throws -> Void)
        throws
    {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            do { try body(coordinatedURL) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError {
            throw error
        }
    }

    /// Makes sure a readable copy of `url` is on this device. A no-op for a
    /// local file. For an iCloud item with no local copy, starts the download
    /// and polls until one exists or `timeout` passes. For one with an older
    /// local copy, starts the download but returns right away.
    nonisolated private static func downloadIfNeeded(_ url: URL, timeout: Duration) async throws {
        let fileManager = FileManager.default
        guard fileManager.isUbiquitousItem(at: url) || placeholderExists(for: url) else { return }
        if downloadingStatus(of: url) == .current { return }
        try fileManager.startDownloadingUbiquitousItem(at: url)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let status = downloadingStatus(of: url)
            if status == .current || status == .downloaded {
                return
            }
            if clock.now >= deadline {
                throw ScriptStoreError.downloadTimedOut
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Reads the iCloud download status through a fresh URL, so a value
    /// cached on an earlier URL instance can't hide a finished download.
    nonisolated private static func downloadingStatus(of url: URL)
        -> URLUbiquitousItemDownloadingStatus?
    {
        let fresh = URL(filePath: url.path(percentEncoded: false))
        return try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
    }

    // MARK: - Placeholder helpers

    /// The real URL an evicted iCloud placeholder stands for:
    /// `.hello.rb.icloud` maps to `hello.rb` in the same directory. `nil` for
    /// anything that isn't a placeholder for a `.rb` file.
    nonisolated static func realURL(forPlaceholder url: URL) -> URL? {
        let fileName = url.lastPathComponent
        guard fileName.hasPrefix("."), fileName.hasSuffix(".rb.icloud") else { return nil }
        let realName = String(fileName.dropFirst().dropLast(".icloud".count))
        guard realName.count > ".rb".count else { return nil }
        return url.deletingLastPathComponent().appending(component: realName)
    }

    /// The placeholder URL iCloud would use for `url` once it's evicted.
    nonisolated private static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(component: ".\(url.lastPathComponent).icloud")
    }

    /// Whether an evicted iCloud placeholder for `url` is on disk.
    nonisolated private static func placeholderExists(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: placeholderURL(for: url).path(percentEncoded: false))
    }

    // MARK: - Name helpers

    /// Throws ``ScriptStoreError/notAScript`` unless `url` is a regular file
    /// right now. Reads through a fresh URL so cached resource values from an
    /// earlier listing can't vouch for what's there now. An evicted iCloud
    /// placeholder throws ``ScriptStoreError/notDownloaded`` instead, after
    /// starting its download.
    nonisolated private static func requireRegularFile(_ url: URL) throws {
        let fresh = URL(filePath: url.path(percentEncoded: false))
        let values = try? fresh.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            if placeholderExists(for: url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                throw ScriptStoreError.notDownloaded
            }
            throw ScriptStoreError.notAScript
        }
    }

    /// Sanitizes a caller-supplied name into a bare base name (no extension):
    /// trims whitespace, drops any path components so the caller can't escape
    /// the directory, and strips a trailing `.rb` so `foo.rb` becomes `foo`.
    /// Throws ``ScriptStoreError/invalidName`` if nothing is left.
    nonisolated private static func sanitizedBaseName(_ name: String) throws -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        base = (base as NSString).lastPathComponent
        if base.hasSuffix(".rb") {
            base = String(base.dropLast(".rb".count))
        }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw ScriptStoreError.invalidName
        }
        return base
    }

    /// Returns the URL to write a new `base.rb` to, appending a `-2`, `-3`, ...
    /// suffix until it finds one that's free, so nothing is ever silently
    /// overwritten. A name taken only by an evicted iCloud placeholder counts
    /// as taken. Used by ``create(name:source:)`` and by ``ScriptStorage``
    /// when it moves local scripts into iCloud.
    nonisolated func uniqueURL(forBaseName base: String) -> URL {
        func isTaken(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                || Self.placeholderExists(for: url)
        }
        let initial = directoryURL.appending(component: base).appendingPathExtension("rb")
        if !isTaken(initial) {
            return initial
        }
        var n = 2
        while true {
            let candidate =
                directoryURL
                .appending(component: "\(base)-\(n)")
                .appendingPathExtension("rb")
            if !isTaken(candidate) {
                return candidate
            }
            n += 1
        }
    }
}
