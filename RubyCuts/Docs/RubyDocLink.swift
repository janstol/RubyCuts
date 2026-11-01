import Foundation

/// A row on the documentation's Ruby tab: a core class or bundled library
/// that opens its official docs in the browser.
///
/// Pure data, `nonisolated` like ``DocTopic``.
nonisolated struct RubyDocLink: Identifiable, Hashable, Sendable {
    /// The class or library name, e.g. `Net::HTTP`.
    let name: String

    /// One line shown under the name, and matched by search.
    let summary: String

    /// Where the row opens.
    let url: URL

    var id: String { name }

    /// The Ruby 3.4 API docs, matching the embedded CRuby 3.4.9.
    static let baseURL = URL(string: "https://docs.ruby-lang.org/en/3.4/")!

    /// A page under ``baseURL``, e.g. `"Net/HTTP.html"`.
    init(name: String, summary: String, path: String) {
        self.init(name: name, summary: summary, url: Self.baseURL.appending(path: path))
    }

    /// A page outside ``baseURL``, for bundled gems that docs.ruby-lang.org
    /// doesn't cover in 3.4 (csv, base64, sqlite3).
    init(name: String, summary: String, url: URL) {
        self.name = name
        self.summary = summary
        self.url = url
    }

    /// The Ruby tab's rows: core classes first, then bundled libraries.
    static let all: [RubyDocLink] = core + libraries

    /// Core classes and modules, available without a `require`.
    static let core: [RubyDocLink] = [
        RubyDocLink(
            name: "String", summary: "Text: slicing, searching, formatting.", path: "String.html"),
        RubyDocLink(name: "Array", summary: "Ordered lists and their methods.", path: "Array.html"),
        RubyDocLink(name: "Hash", summary: "Key-value maps.", path: "Hash.html"),
        RubyDocLink(name: "Integer", summary: "Whole numbers.", path: "Integer.html"),
        RubyDocLink(name: "Float", summary: "Floating-point numbers.", path: "Float.html"),
        RubyDocLink(
            name: "Time", summary: "Dates and times with a clock component.", path: "Time.html"),
        RubyDocLink(name: "Regexp", summary: "Regular expressions.", path: "Regexp.html"),
        RubyDocLink(name: "File", summary: "Reading and writing files.", path: "File.html"),
        RubyDocLink(name: "Dir", summary: "Listing and walking directories.", path: "Dir.html"),
        RubyDocLink(
            name: "Kernel", summary: "puts, format, raise and other global methods.",
            path: "Kernel.html"),
        RubyDocLink(
            name: "Enumerable", summary: "map, select, sort_by and friends, shared by collections.",
            path: "Enumerable.html"),
    ]

    /// Bundled standard libraries and gems, loaded with `require`.
    static let libraries: [RubyDocLink] = [
        RubyDocLink(
            name: "JSON", summary: "Parse and generate JSON. require 'json'", path: "JSON.html"),
        RubyDocLink(
            name: "Net::HTTP", summary: "HTTP and HTTPS requests. require 'net/http'",
            path: "Net/HTTP.html"),
        RubyDocLink(name: "URI", summary: "Parse and build URLs. require 'uri'", path: "URI.html"),
        RubyDocLink(
            name: "CSV", summary: "Read and write CSV. require 'csv'",
            url: URL(string: "https://ruby.github.io/csv/CSV.html")!),
        RubyDocLink(
            name: "Base64", summary: "Base64 encoding. require 'base64'",
            url: URL(string: "https://docs.ruby-lang.org/en/3.3/Base64.html")!),
        RubyDocLink(name: "Date", summary: "Calendar dates. require 'date'", path: "Date.html"),
        RubyDocLink(
            name: "OpenSSL", summary: "Digests, HMAC and ciphers. require 'openssl'",
            path: "OpenSSL.html"),
        RubyDocLink(
            name: "YAML", summary: "Parse and emit YAML (Psych). require 'yaml'", path: "Psych.html"
        ),
        RubyDocLink(
            name: "SQLite3", summary: "SQLite databases. require 'sqlite3'",
            url: URL(string: "https://sparklemotion.github.io/sqlite3-ruby/SQLite3/Database.html")!),
    ]
}
