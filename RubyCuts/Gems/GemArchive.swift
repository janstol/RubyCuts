import Foundation

/// An error raised while extracting a `.gem` archive.
enum GemArchiveError: Error, Sendable {
    /// The archive contains an entry Ruby's extractor rejected -- a path
    /// escape, a symlink/hardlink, or a `.gem` missing `data.tar.gz`
    /// entirely. The message is the Ruby exception's `to_s`.
    case unsafeArchive(String)

    /// The archive's payload contains `ext/**/extconf.rb` -- a C extension,
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
/// filesystem paths only -- the gem's bytes never cross the Swift/Ruby
/// boundary as embedded data, only as a path Ruby reads with `File.open`.
///
/// Two safety rules are non-negotiable, enforced inside the Ruby extractor
/// (see ``tarReaderSource``): an entry whose normalized path would escape
/// `destination` (`../`, an absolute path, a symlink/hardlink) is rejected,
/// and a payload containing `ext/**/extconf.rb` fails the whole extraction --
/// better to refuse the install with an explanation than ship a gem that
/// silently can't `require`.
enum GemArchive {
    /// Extracts `gemFileURL` (a downloaded `.gem`) into `destination`,
    /// creating it if needed. On success, `destination` holds the gem's
    /// payload -- typically a `lib/` directory among others. Runs on
    /// ``RubyRuntime``'s dedicated VM thread, like every other VM call --
    /// `async` because reaching that thread from the caller's actor is a
    /// real hop, not a same-actor call.
    static func extract(gemFileURL: URL, destination: URL) async throws {
        let gemPathB64 = RubyRuntime.base64(gemFileURL.path)
        let destPathB64 = RubyRuntime.base64(destination.path)

        let code = """
            \(tarReaderSource)
            RubyCutsGemArchive.extract(
              Base64.decode64("\(gemPathB64)"),
              Base64.decode64("\(destPathB64)")
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
    /// (unlike `NativeBridge.installDefaults()`) -- nothing outside a gem
    /// install needs it, and boot cost should stay at zero.
    ///
    /// Reads POSIX ustar headers by hand via `String#unpack`: 100-byte name,
    /// 8-byte octal size... down to the 155-byte prefix field RubyGems' own
    /// `Gem::Package::TarWriter` uses for paths over 100 bytes. GNU
    /// long-name extensions (typeflag `L`) aren't handled -- real pure-Ruby
    /// gems don't need them, and the plan accepts that as a V1 scope limit.
    private static let tarReaderSource = #"""
        require 'zlib'
        require 'stringio'
        require 'base64'
        require 'fileutils'

        module RubyCutsGemArchive
          class UnsafeArchiveError < StandardError; end

          # offset:size -- name:100 mode:8 uid:8 gid:8 size:12 mtime:12
          # chksum:8 typeflag:1 linkname:100 magic:6 version:2 uname:32
          # gname:32 devmajor:8 devminor:8 prefix:155 (+12 unused pad, left
          # off since #unpack ignores trailing bytes it doesn't consume).
          TAR_HEADER_FORMAT = "a100a8a8a8a12a12a8aa100a6a2a32a32a8a8a155"

          def self.read_tar_entries(io)
            entries = []
            loop do
              header = io.read(512)
              break if header.nil? || header.bytesize < 512
              break if header.bytes.all?(&:zero?)

              fields = header.unpack(TAR_HEADER_FORMAT)
              name = fields[0].to_s.delete("\0")
              typeflag = fields[7].to_s
              prefix = fields[15].to_s.delete("\0")
              size_field = fields[4].to_s.delete("\0").strip
              size = size_field.empty? ? 0 : size_field.to_i(8)
              full_name = prefix.empty? ? name : "#{prefix}/#{name}"
              padded_size = ((size + 511) / 512) * 512

              content =
                if size.positive?
                  (io.read(padded_size) || "")[0, size]
                else
                  ""
                end

              next if full_name.empty?
              next if %w[x g].include?(typeflag)  # pax extended headers -- unsupported, skipped

              entries << { name: full_name, typeflag: typeflag, content: content }
            end
            entries
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

          def self.extract(gem_path, dest_dir)
            outer = File.open(gem_path, "rb") { |f| read_tar_entries(f) }
            data_entry = outer.find { |e| e[:name] == "data.tar.gz" }
            raise UnsafeArchiveError, "data.tar.gz not found in gem" unless data_entry

            inner_tar = Zlib::GzipReader.new(StringIO.new(data_entry[:content])).read
            inner_entries = read_tar_entries(StringIO.new(inner_tar))

            extconf = inner_entries.find { |e| e[:name] =~ %r{(^|/)ext/.*extconf\.rb\z} }
            if extconf
              raise UnsafeArchiveError,
                "gem contains a C extension (#{extconf[:name]}) -- not supported"
            end

            FileUtils.mkdir_p(dest_dir)
            inner_entries.each do |entry|
              next if entry[:typeflag] == "5" || entry[:name].end_with?("/")

              if %w[1 2].include?(entry[:typeflag])
                raise UnsafeArchiveError, "unsafe entry type in archive: #{entry[:name]}"
              end

              target = safe_join(dest_dir, entry[:name])
              FileUtils.mkdir_p(File.dirname(target))
              File.open(target, "wb") { |f| f.write(entry[:content]) }
            end

            "ok"
          end
        end
        """#
}
