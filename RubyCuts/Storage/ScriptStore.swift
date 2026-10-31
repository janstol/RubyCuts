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
}

/// A value-type store over a directory of `.rb` files, the backing layer for
/// Phase 3's script list and Phase 5's "Run Ruby Script" App Intent. No
/// SwiftData: the PRD stores raw `.rb` files, so the filesystem *is* the
/// database, and this type is a thin set of operations over one directory URL.
///
/// `Sendable` because the only stored state is a `let directoryURL`; the
/// filesystem is the mutable backing store, so there's no in-process state to
/// guard.
///
/// **iCloud swap point:** the store is built around ``directoryURL`` so that
/// moving the scripts into an iCloud ubiquitous container is a one-line change
/// to ``userScripts``: the CRUD methods below don't change. iCloud ubiquity
/// wiring and `NSMetadataQuery` on-demand discovery are deferred (backlog
/// Phase 2 items 1-3) until the Apple Developer portal capability is enabled;
/// ``list()`` is the single method `NSMetadataQuery` will replace.
///
/// **Known follow-up:** the I/O methods here are synchronous and run on
/// whatever actor calls them, unlike ``RubyRuntime`` (which now has its own
/// dedicated thread; see its doc comment). File reads/writes for small
/// scripts are fast, so this is fine for the walking skeleton. Backgrounding
/// long writes (a large script pasted in, or enumerating a directory with
/// many files) is a later-phase concern.
///
/// Like ``Script``, every member is `nonisolated` to opt out of the app target's
/// MainActor-by-default isolation: the store holds no actor-coupled state (only
/// a `let directoryURL`), so it's usable from any context: the nonisolated
/// test target today, and background I/O in a later phase.
struct ScriptStore: Sendable {
    /// The directory this store reads and writes. Stable for the life of the
    /// store; the filesystem is the backing store.
    nonisolated let directoryURL: URL

    /// The app's script store. Today: the sandbox Documents directory. This is
    /// the single iCloud swap point. Replace the body with
    /// `FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.dev.stol.RubyCuts").appending(component: "Documents")`
    /// once the portal capability is on; the CRUD methods below don't change.
    nonisolated static var userScripts: ScriptStore {
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
    /// This is the file-discovery deliverable; iCloud's `NSMetadataQuery`
    /// replaces only this method later (same output shape, different discovery
    /// primitive). Uses `contentsOfDirectory` (not a recursive enumerator)
    /// because the store writes top-level files only; NSMetadataQuery scopes by
    /// searchScopes rather than recursion depth, so this flat behavior carries
    /// over to iCloud.
    ///
    /// Requests `.contentModificationDateKey` so each ``Script/modifiedAt`` is
    /// populated from the same directory scan: `contentsOfDirectory` already
    /// prefetches it into the URL, so this adds no per-file `stat` calls. A URL
    /// whose date can't be read gets `modifiedAt == nil` rather than failing
    /// the whole listing.
    ///
    /// Sort stays by name here; re-sorting by other criteria (e.g. date) is
    /// ``ScriptLibrary``'s job, so this method's contract (name-sorted
    /// `[Script]`) doesn't change for iCloud's replacement to match.
    nonisolated func list() throws -> [Script] {
        try ensureDirectory()
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: Array(keys)
        )
        return
            urls
            .filter { $0.pathExtension == "rb" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { return nil }
                return Script(url: url, modifiedAt: values?.contentModificationDate)
            }
            .sorted { $0.name < $1.name }
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
        let url = try uniqueURL(forBaseName: base)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Script(url: url)
    }

    /// Reads the script's source from disk on demand. A script file can be
    /// large, so source is never held on the ``Script`` model. Read it when
    /// you need it, through this method.
    nonisolated func source(of script: Script) throws -> String {
        try String(contentsOf: script.url, encoding: .utf8)
    }

    /// Overwrites the script's file with `source`. Atomic, so a crash mid-write
    /// leaves the previous contents intact.
    nonisolated func write(_ script: Script, source: String) throws {
        try source.write(to: script.url, atomically: true, encoding: .utf8)
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
        try FileManager.default.moveItem(at: script.url, to: target)
        return Script(url: target)
    }

    /// Deletes the script's file from disk. Throws
    /// ``ScriptStoreError/notAScript`` instead if the URL isn't a regular
    /// file: `removeItem` deletes a directory recursively, and a symlink
    /// isn't something this store created. Checked at delete time rather than
    /// trusting ``list()``, since the file can change in between (the Files
    /// app, or iCloud later).
    nonisolated func delete(_ script: Script) throws {
        try Self.requireRegularFile(script.url)
        try FileManager.default.removeItem(at: script.url)
    }

    // MARK: - Name helpers

    /// Throws ``ScriptStoreError/notAScript`` unless `url` is a regular file
    /// right now. Reads through a fresh URL so cached resource values from an
    /// earlier listing can't vouch for what's there now.
    nonisolated private static func requireRegularFile(_ url: URL) throws {
        let fresh = URL(filePath: url.path(percentEncoded: false))
        let values = try? fresh.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
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
    /// suffix until it finds one that doesn't exist, so `create` never silently
    /// overwrites an existing file.
    nonisolated private func uniqueURL(forBaseName base: String) throws -> URL {
        let initial = directoryURL.appending(component: base).appendingPathExtension("rb")
        if !FileManager.default.fileExists(atPath: initial.path) {
            return initial
        }
        var n = 2
        while true {
            let candidate =
                directoryURL
                .appending(component: "\(base)-\(n)")
                .appendingPathExtension("rb")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }
}
