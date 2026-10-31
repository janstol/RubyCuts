import Foundation

/// An error raised while extracting a `.gem` archive.
enum GemArchiveError: Error, Sendable {
    /// The archive contains an entry Ruby's extractor rejected: a path
    /// escape, a symlink/hardlink, a malformed or truncated tar, an archive
    /// over ``GemArchive/Limits``, or a `.gem` missing `data.tar.gz`
    /// entirely. The message is the Ruby exception's `to_s`.
    case unsafeArchive(String)

    /// The archive's payload contains `ext/**/extconf.rb`, a C extension,
    /// which can't be dynamically loaded under App Store W^X rules. The
    /// message names the offending file.
    case containsCExtension(String)
}

/// Extracts a downloaded `.gem` file into a destination directory.
///
/// A `.gem` is an uncompressed tar containing `metadata.gz`, `data.tar.gz`,
/// and `checksums.yaml.gz`. Extraction happens entirely inside the Ruby VM,
/// not in Swift: `Init_zlib` is already statically linked into
/// `libruby-static.a`, so `Zlib::GzipReader` plus a small hand-rolled tar
/// reader (below, held as Ruby source) does the decoding, instead of
/// hand-rolling gzip over Apple's Compression framework. Swift's job is
/// filesystem paths only: the gem's bytes never cross the Swift/Ruby
/// boundary as embedded data, only as a path Ruby reads with `File.open`.
///
/// Two safety rules are non-negotiable, enforced inside the Ruby extractor
/// (see ``tarReaderSource``): an entry whose normalized path would escape
/// `destination` (`../`, an absolute path, a symlink/hardlink) is rejected,
/// and a payload containing `ext/**/extconf.rb` fails the whole extraction.
/// Better to refuse the install with an explanation than ship a gem that
/// silently can't `require`.
///
/// Memory stays bounded: the payload is decompressed and written out in
/// chunks rather than inflated whole, and ``Limits`` caps how much it may
/// unpack to, so a small, highly compressible archive can't exhaust memory
/// or disk.
enum GemArchive {
    /// How large a gem's payload may be once unpacked.
    struct Limits: Sendable {
        /// The most bytes all entries together may declare. Checked against
        /// each tar header before its body is read, so an archive over the
        /// limit is rejected without inflating it.
        var maxUnpackedBytes: Int

        /// The most entries (files, directories) the payload may contain.
        var maxEntries: Int

        /// 100 MiB and 10,000 entries: far above any real pure-Ruby gem,
        /// far below what would strain a phone.
        static let standard = Limits(maxUnpackedBytes: 100 * 1_048_576, maxEntries: 10_000)
    }

    /// Extracts `gemFileURL` (a downloaded `.gem`) into `destination`,
    /// creating it. On success, `destination` holds the gem's payload,
    /// typically a `lib/` directory among others. On failure nothing is left
    /// at `destination`: entries are written to a temporary sibling directory
    /// that is renamed into place only once the whole archive has extracted.
    ///
    /// Runs on ``RubyRuntime``'s dedicated VM thread, like every other VM
    /// call: `async` because reaching that thread from the caller's actor is
    /// a real hop, not a same-actor call.
    static func extract(
        gemFileURL: URL, destination: URL, limits: Limits = .standard
    ) async throws {
        let gemPathB64 = RubyRuntime.base64(gemFileURL.path)
        let destPathB64 = RubyRuntime.base64(destination.path)

        let code = """
            \(tarReaderSource)
            RubyCutsGemArchive.extract(
              Base64.decode64("\(gemPathB64)"),
              Base64.decode64("\(destPathB64)"),
              \(limits.maxUnpackedBytes),
              \(limits.maxEntries)
            )
            """

        do {
            _ = try await RubyRuntime.shared.evaluate(code)
        } catch RubyError.evaluationFailed(let message) {
            if message.contains("C extension") {
                throw GemArchiveError.containsCExtension(message)
            }
            throw GemArchiveError.unsafeArchive(message)
        }
    }

    /// The tar reader + extractor, evaluated on demand rather than at boot
    /// (unlike `NativeBridge.installDefaults()`): nothing outside a gem
    /// install needs it, and boot cost should stay at zero.
    ///
    /// Reads POSIX ustar headers by hand via `String#unpack`: 100-byte name,
    /// 8-byte octal size... down to the 155-byte prefix field RubyGems' own
    /// `Gem::Package::TarWriter` uses for paths over 100 bytes. GNU
    /// long-name extensions (typeflag `L`) aren't handled: real pure-Ruby
    /// gems don't need them, and the plan accepts that as a V1 scope limit.
    ///
    /// Strict about structure: every header's checksum is verified, size
    /// fields must be plain octal, and a partial header or an entry body
    /// (padding included) shorter than its header declares fails the whole
    /// extraction.
    ///
    /// Streams: `each_tar_entry` yields one header at a time with a body
    /// reader that hands the content over in 64 KiB chunks, and the payload
    /// is read straight from the `GzipReader` instead of being inflated into
    /// one string first. The entry count and declared sizes are checked
    /// against the limits before a body is read. Writing goes to a
    /// `.partial-*` sibling of the destination that is removed on any
    /// failure, which keeps the old "a bad archive writes nothing" guarantee.
    private static let tarReaderSource = #"""
        require 'zlib'
        require 'stringio'
        require 'base64'
        require 'fileutils'
        require 'securerandom'

        module RubyCutsGemArchive
          class UnsafeArchiveError < StandardError; end

          # Field sizes below, in bytes: name:100 mode:8 uid:8 gid:8 size:12 mtime:12
          # chksum:8 typeflag:1 linkname:100 magic:6 version:2 uname:32
          # gname:32 devmajor:8 devminor:8 prefix:155 (+12 unused pad, left
          # off since #unpack ignores trailing bytes it doesn't consume).
          TAR_HEADER_FORMAT = "a100a8a8a8a12a12a8aa100a6a2a32a32a8a8a155"

          # A numeric header field: octal digits, optionally ended by NUL or
          # space padding. Anything else (an empty field, a stray character,
          # GNU's base-256 encoding for huge sizes) is malformed: `to_i(8)`
          # would quietly read "12x" as 10, or garbage as 0.
          def self.octal_field(raw, label, entry_name)
            digits = raw.sub(/[\0 ]+\z/, "")
            unless digits.match?(/\A[0-7]+\z/)
              raise UnsafeArchiveError, "malformed #{label} field in archive entry #{entry_name.inspect}"
            end
            digits.to_i(8)
          end

          # The header checksum is the sum of all 512 header bytes with the
          # 8-byte checksum field itself counted as spaces. POSIX says
          # unsigned bytes; some old writers summed signed ones, so either
          # is accepted.
          def self.verify_checksum(header, entry_name)
            stored = octal_field(header.byteslice(148, 8), "checksum", entry_name)
            blanked = header.byteslice(0, 148) + (" " * 8) + header.byteslice(156, 356)
            unsigned = blanked.unpack("C*").sum
            signed = blanked.unpack("c*").sum
            unless stored == unsigned || stored == signed
              raise UnsafeArchiveError, "bad header checksum in archive entry #{entry_name.inspect}"
            end
          end

          # Yields each entry's header ({name:, typeflag:, size:}) and a body
          # reader. Calling the reader with a block hands it the entry's
          # content in chunks; an entry whose body the block didn't read is
          # skipped afterwards. Either way the whole body, padding included,
          # must be there: a checksum over the download only proves the bytes
          # match what was advertised, not that the tar inside is complete.
          def self.each_tar_entry(io)
            loop do
              header = io.read(512)
              # A clean end of data at a block boundary ends the archive (the
              # two zero blocks a writer appends are optional in practice).
              # A partial header means the archive was cut short.
              break if header.nil?
              if header.bytesize < 512
                raise UnsafeArchiveError, "truncated tar header (#{header.bytesize} of 512 bytes)"
              end
              break if header.bytes.all?(&:zero?)

              fields = header.unpack(TAR_HEADER_FORMAT)
              name = fields[0].to_s.delete("\0")
              prefix = fields[15].to_s.delete("\0")
              full_name = prefix.empty? ? name : "#{prefix}/#{name}"
              verify_checksum(header, full_name)
              size = octal_field(fields[4].to_s, "size", full_name)
              padded_size = ((size + 511) / 512) * 512

              consumed = false
              body = lambda do |&sink|
                consumed = true
                read = 0
                while read < padded_size
                  chunk = io.read([padded_size - read, 65_536].min)
                  if chunk.nil? || chunk.empty?
                    raise UnsafeArchiveError,
                      "truncated archive entry #{full_name.inspect} (#{read} of #{padded_size} bytes)"
                  end
                  content_left = size - read
                  sink&.call(content_left >= chunk.bytesize ? chunk : chunk.byteslice(0, content_left)) if content_left.positive?
                  read += chunk.bytesize
                end
              end

              yield({ name: full_name, typeflag: fields[7].to_s, size: size }, body)
              body.call unless consumed
            end
          end

          # Rejects an absolute path or one containing "..", and strips "."
          # components (a common "./lib/foo.rb" tar convention) before
          # joining onto `base`. A malicious .gem must not be able to write
          # outside its own destination directory.
          def self.safe_join(base, relative)
            if relative.start_with?("/")
              raise UnsafeArchiveError, "unsafe path in archive: #{relative}"
            end

            parts = relative.split("/").reject { |p| p.empty? || p == "." }
            if parts.include?("..") || parts.empty?
              raise UnsafeArchiveError, "unsafe path in archive: #{relative}"
            end

            File.join(base, *parts)
          end

          # The compressed payload. Held in memory, but it's at most the size
          # of the downloaded .gem, which the installer already caps.
          def self.read_data_entry(gem_path)
            data = nil
            File.open(gem_path, "rb") do |file|
              each_tar_entry(file) do |entry, body|
                next unless entry[:name] == "data.tar.gz"
                # No capacity hint from entry[:size]: it's whatever the
                # header claims, and the body reader fails on a short body
                # anyway.
                buffer = String.new
                body.call { |chunk| buffer << chunk }
                data = buffer
              end
            end
            raise UnsafeArchiveError, "data.tar.gz not found in gem" unless data
            data
          end

          def self.extract(gem_path, dest_dir, max_bytes, max_entries)
            data = read_data_entry(gem_path)
            partial = "#{dest_dir}.partial-#{SecureRandom.hex(8)}"
            FileUtils.mkdir_p(partial)
            begin
              entry_count = 0
              declared_bytes = 0
              gzip = Zlib::GzipReader.new(StringIO.new(data))
              each_tar_entry(gzip) do |entry, body|
                name = entry[:name]
                typeflag = entry[:typeflag]
                next if name.empty?
                next if %w[x g].include?(typeflag)  # pax extended headers, unsupported and skipped

                entry_count += 1
                if entry_count > max_entries
                  raise UnsafeArchiveError, "archive has more than #{max_entries} entries, too large to install"
                end
                declared_bytes += entry[:size]
                if declared_bytes > max_bytes
                  raise UnsafeArchiveError,
                    "archive unpacks to more than #{max_bytes / 1_048_576} MB, too large to install"
                end

                if name =~ %r{(^|/)ext/.*extconf\.rb\z}
                  raise UnsafeArchiveError, "gem contains a C extension (#{name}), not supported"
                end
                next if typeflag == "5" || name.end_with?("/")
                if %w[1 2].include?(typeflag)
                  raise UnsafeArchiveError, "unsafe entry type in archive: #{name}"
                end

                target = safe_join(partial, name)
                FileUtils.mkdir_p(File.dirname(target))
                File.open(target, "wb") { |file| body.call { |chunk| file.write(chunk) } }
              end
              gzip.close
              File.rename(partial, dest_dir)
            rescue Exception
              FileUtils.rm_rf(partial)
              raise
            end

            "ok"
          end
        end
        """#
}
