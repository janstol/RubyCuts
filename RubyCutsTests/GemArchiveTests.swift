import Foundation
@testable import RubyCuts
import Testing

/// A marker type with no other purpose than locating the test bundle:
/// `RubyCutsTests` is app-hosted (see `RubyRuntime.bundledStdlibURL`'s
/// comment), so `Bundle.main` during a test run resolves to `RubyCuts.app`,
/// not the `.xctest` bundle the `Fixtures/` directory is copied into.
/// `Bundle(for:)` is the standard way to recover the right bundle without
/// SPM's `Bundle.module`.
private final class FixtureBundleMarker {}

// Drives `RubyRuntime.shared` (through `GemArchive.extract`, and through the
// `gzip(_:)` helper below), so this suite joins the same `.serialized`
// contract `RubyRuntimeTests` documents: the embedded VM is a single
// non-thread-safe interpreter. Nested under ``EmbeddedRubyTests`` so
// `.serialized` covers `RubyRuntimeTests` and `NativeBridgeTests` too; see
// that type's doc comment.
extension EmbeddedRubyTests {
    @MainActor
    @Suite(.serialized)
    struct GemArchiveTests {

        // MARK: - A real .gem fixture

        @Test func extractsARealGemFixture() async throws {
            let gemURL = try Self.fixtureURL("rubycuts_fixture-0.0.1.gem")
            let destination = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            try await GemArchive.extract(gemFileURL: gemURL, destination: destination)

            let mainFile = destination.appending(component: "lib/rubycuts_fixture.rb")
            let nestedFile = destination.appending(component: "lib/rubycuts_fixture/nested.rb")
            #expect(FileManager.default.fileExists(atPath: mainFile.path))
            #expect(FileManager.default.fileExists(atPath: nestedFile.path))

            let nestedContents = try String(contentsOf: nestedFile, encoding: .utf8)
            #expect(nestedContents.contains("nested-ok"))
        }

        // MARK: - Safety: path escapes

        @Test func rejectsAnEntryThatEscapesViaDotDot() async throws {
            let gemURL = try await Self.makeMaliciousGem(innerEntries: [
                (name: "../../etc/evil.rb", content: Data("evil".utf8), typeflag: "0", linkname: "")
            ])
            let destination = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            await #expect(throws: GemArchiveError.self) {
                try await GemArchive.extract(gemFileURL: gemURL, destination: destination)
            }
        }

        @Test func rejectsAnAbsolutePathEntry() async throws {
            let gemURL = try await Self.makeMaliciousGem(innerEntries: [
                (name: "/etc/evil.rb", content: Data("evil".utf8), typeflag: "0", linkname: "")
            ])
            let destination = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            await #expect(throws: GemArchiveError.self) {
                try await GemArchive.extract(gemFileURL: gemURL, destination: destination)
            }
        }

        @Test func rejectsASymlinkEntry() async throws {
            let gemURL = try await Self.makeMaliciousGem(innerEntries: [
                (name: "lib/evil.rb", content: Data(), typeflag: "2", linkname: "/etc/passwd")
            ])
            let destination = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            await #expect(throws: GemArchiveError.self) {
                try await GemArchive.extract(gemFileURL: gemURL, destination: destination)
            }
        }

        // MARK: - Safety: C extensions

        @Test func refusesAGemContainingAnExtconf() async throws {
            let gemURL = try await Self.makeMaliciousGem(innerEntries: [
                (name: "lib/foo.rb", content: Data("puts 1".utf8), typeflag: "0", linkname: ""),
                (
                    name: "ext/foo/extconf.rb", content: Data("create_makefile('foo')".utf8),
                    typeflag: "0", linkname: ""
                ),
            ])
            let destination = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            do {
                try await GemArchive.extract(gemFileURL: gemURL, destination: destination)
                Issue.record("expected extract to throw on a C-extension gem")
            } catch GemArchiveError.containsCExtension(let detail) {
                #expect(detail.contains("extconf.rb"))
            } catch {
                Issue.record("expected GemArchiveError.containsCExtension, got \(error)")
            }
        }

        // MARK: - Integrity: malformed tar structure
        //
        // The download checksum only proves the bytes match what rubygems.org
        // advertised; it says nothing about whether the tar inside is whole.
        // Each malformed case must fail extraction and write nothing.

        @Test func aHandBuiltArchiveWithValidHeadersExtracts() async throws {
            // Guards the fixture builder itself: if its checksums were wrong,
            // every rejection test below would pass for the wrong reason.
            let gemURL = try await Self.makeMaliciousGem(innerEntries: [
                (name: "lib/ok.rb", content: Data("puts 1".utf8), typeflag: "0", linkname: "")
            ])
            let destination = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            try await GemArchive.extract(gemFileURL: gemURL, destination: destination)

            let file = destination.appending(component: "lib/ok.rb")
            #expect(try String(contentsOf: file, encoding: .utf8) == "puts 1")
        }

        @Test func rejectsATruncatedInnerHeader() async throws {
            let complete = Self.tarEntry(name: "lib/a.rb", content: Data("a".utf8))
            let partialHeader = Data("lib/b.rb".utf8) + Data(count: 92)
            try await Self.expectRejected(
                innerTar: complete + partialHeader, mentioning: "truncated")
        }

        @Test func rejectsAShortFileBody() async throws {
            let entry = Self.tarEntry(name: "lib/a.rb", content: Data(repeating: 0x61, count: 100))
            try await Self.expectRejected(innerTar: entry.prefix(512 + 50), mentioning: "truncated")
        }

        @Test func rejectsAMissingBodyPadding() async throws {
            // The 100 content bytes are all there, but the block padding
            // after them isn't.
            let entry = Self.tarEntry(name: "lib/a.rb", content: Data(repeating: 0x61, count: 100))
            try await Self.expectRejected(
                innerTar: entry.prefix(512 + 100), mentioning: "truncated")
        }

        @Test(arguments: ["0000000003x", "", "-0000000003"])
        func rejectsAnInvalidSizeField(sizeField: String) async throws {
            let entry = Self.tarEntry(
                name: "lib/a.rb", content: Data("abc".utf8), sizeField: sizeField)
            try await Self.expectRejected(innerTar: entry, mentioning: "size field")
        }

        @Test func rejectsABadHeaderChecksum() async throws {
            var entry = Self.tarEntry(name: "lib/a.rb", content: Data("abc".utf8))
            entry[0] = UInt8(ascii: "m")  // "mib/a.rb", after the checksum was computed
            try await Self.expectRejected(innerTar: entry, mentioning: "checksum")
        }

        @Test func rejectsATruncatedGemFile() async throws {
            // The outer .gem tar, cut off partway through data.tar.gz's body:
            // what an interrupted download that somehow passed the size check
            // would look like.
            let gemURL = try await Self.makeMaliciousGem(innerEntries: [
                (name: "lib/ok.rb", content: Data("puts 1".utf8), typeflag: "0", linkname: "")
            ])
            let bytes = try Data(contentsOf: gemURL)
            try bytes.prefix(512 + 10).write(to: gemURL)
            let destination = Self.tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            await #expect(throws: GemArchiveError.self) {
                try await GemArchive.extract(gemFileURL: gemURL, destination: destination)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }

        /// Asserts that a gem wrapping `innerTar` fails extraction with an
        /// ``GemArchiveError/unsafeArchive(_:)`` whose message mentions
        /// `keyword`, and that nothing was written to the destination.
        private static func expectRejected(
            innerTar: Data, mentioning keyword: String
        ) async throws {
            let gemURL = try await makeGem(innerTar: innerTar)
            let destination = tempDirectory()
            defer { try? FileManager.default.removeItem(at: destination) }

            do {
                try await GemArchive.extract(gemFileURL: gemURL, destination: destination)
                Issue.record("expected extraction to fail")
            } catch GemArchiveError.unsafeArchive(let message) {
                #expect(message.contains(keyword), "\(message)")
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }

        // MARK: - Fixture helpers

        static func fixtureURL(_ name: String) throws -> URL {
            let bundle = Bundle(for: FixtureBundleMarker.self)
            // Whether `PBXFileSystemSynchronizedRootGroup` preserves the
            // `Fixtures/` subdirectory in `Copy Bundle Resources` (vs. flattening
            // it) isn't guaranteed, so try both.
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: nil) {
                return url
            }
            throw TestFixtureError.fixtureNotFound(name)
        }

        private static func tempDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appending(component: "RubyCutsTests-gem-extract-\(UUID().uuidString)")
        }

        /// Builds a `.gem` (an outer, uncompressed tar containing one
        /// `data.tar.gz` entry) whose inner tar holds exactly `innerEntries`,
        /// hand-built to exercise ``GemArchive``'s safety rules: no real
        /// `gem build` can produce a path-escaping or symlinked entry, since
        /// RubyGems itself won't let you.
        private static func makeMaliciousGem(
            innerEntries: [(name: String, content: Data, typeflag: Character, linkname: String)]
        ) async throws -> URL {
            try await makeGem(innerTar: tar(innerEntries))
        }

        /// Wraps raw inner tar bytes, well-formed or deliberately not, in a
        /// `.gem` whose outer tar is valid.
        private static func makeGem(innerTar: Data) async throws -> URL {
            let gzippedInner = try await gzip(innerTar)
            let outerTar = tar([
                (name: "data.tar.gz", content: gzippedInner, typeflag: "0", linkname: "")
            ])

            let gemURL = tempDirectory().appendingPathExtension("gem")
            try FileManager.default.createDirectory(
                at: gemURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try outerTar.write(to: gemURL)
            return gemURL
        }

        /// A minimal ustar tar builder: real enough for
        /// ``GemArchive/tarReaderSource``'s reader, including a valid header
        /// checksum, but not a general-purpose tar writer.
        private static func tar(
            _ entries: [(name: String, content: Data, typeflag: Character, linkname: String)]
        ) -> Data {
            entries.reduce(into: Data()) { data, entry in
                data += tarEntry(
                    name: entry.name, content: entry.content, typeflag: entry.typeflag,
                    linkname: entry.linkname
                )
            }
        }

        /// One tar entry. `sizeField` overrides the size header (to build a
        /// malformed one); the checksum is computed over whatever ends up in
        /// the header, so the header is otherwise well-formed.
        static func tarEntry(
            name: String, content: Data, typeflag: Character = "0", linkname: String = "",
            sizeField: String? = nil
        ) -> Data {
            func field(_ string: String, length: Int) -> Data {
                var bytes = Array(string.utf8.prefix(length))
                bytes += Array(repeating: 0, count: length - bytes.count)
                return Data(bytes)
            }
            func octalSizeField(_ value: Int, length: Int) -> Data {
                let octal = String(value, radix: 8)
                let padded = String(repeating: "0", count: max(0, length - 1 - octal.count)) + octal
                return field(padded, length: length)
            }

            var header = Data()
            header += field(name, length: 100)  // name
            header += field("0000644", length: 8)  // mode
            header += field("0000000", length: 8)  // uid
            header += field("0000000", length: 8)  // gid
            if let sizeField {
                header += field(sizeField, length: 12)  // size, deliberately malformed
            } else {
                header += octalSizeField(content.count, length: 12)  // size
            }
            header += field("00000000000", length: 12)  // mtime
            header += field("        ", length: 8)  // chksum: spaces while summing, filled in below
            header += field(String(typeflag), length: 1)  // typeflag
            header += field(linkname, length: 100)  // linkname
            header += field("ustar", length: 6)  // magic
            header += field("00", length: 2)  // version
            header += field("", length: 32)  // uname
            header += field("", length: 32)  // gname
            header += field("", length: 8)  // devmajor
            header += field("", length: 8)  // devminor
            header += field("", length: 155)  // prefix
            header += Data(count: 12)  // pad to 512

            let checksum = header.reduce(0) { $0 + Int($1) }
            let checksumField = String(format: "%06o", checksum) + "\0 "
            header.replaceSubrange(148..<156, with: Data(checksumField.utf8))

            var body = content
            let remainder = body.count % 512
            if remainder != 0 {
                body += Data(count: 512 - remainder)
            }
            return header + body
        }

        /// Gzips `data` through the embedded Ruby VM's `Zlib::GzipWriter`:
        /// `Init_zlib` is statically linked (see ``GemArchive``'s doc comment),
        /// so this is the same primitive real gem downloads decompress with, not
        /// a Swift-side approximation.
        private static func gzip(_ data: Data) async throws -> Data {
            let code = """
                require 'zlib'; require 'stringio'; require 'base64'
                io = StringIO.new
                io.set_encoding(Encoding::BINARY)
                writer = Zlib::GzipWriter.new(io)
                writer.write(Base64.decode64("\(data.base64EncodedString())"))
                writer.close
                Base64.strict_encode64(io.string)
                """
            let resultB64 = try await RubyRuntime.shared.evaluate(code)
            guard let gzipped = Data(base64Encoded: resultB64) else {
                throw TestFixtureError.gzipFailed
            }
            return gzipped
        }

        private enum TestFixtureError: Error {
            case fixtureNotFound(String)
            case gzipFailed
        }
    }
}
