import Foundation
@testable import RubyCuts
import Testing

struct ScriptLinkTests {
    @Test(arguments: ["hello.rb", "My Script.rb", "naïve café.rb", "a&b=c?.rb", "#1.rb"])
    func fileNameRoundTrips(_ fileName: String) {
        let url = ScriptLink.url(forFileName: fileName)
        #expect(url.scheme == "rubycuts")
        #expect(ScriptLink.fileName(from: url) == fileName)
    }

    @Test(arguments: [
        "https://script?name=hello.rb",
        "rubycuts://gem?name=hello.rb",
        "rubycuts://script",
        "rubycuts://script?name=",
        "rubycuts://script?name=..",
        "rubycuts://script?name=../secret.rb",
        "rubycuts://script?name=sub/dir.rb",
        "rubycuts://script?other=hello.rb",
    ])
    func rejectsAnythingButAPlainFileName(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(ScriptLink.fileName(from: url) == nil)
    }

    @Test func schemeAndHostAreCaseInsensitive() throws {
        let url = try #require(URL(string: "RubyCuts://Script?name=hello.rb"))
        #expect(ScriptLink.fileName(from: url) == "hello.rb")
    }
}

// The library's half: holding a link's request until the list has loaded the script.
@MainActor
struct ScriptLibraryOpenRequestTests {
    private func makeStore() throws -> ScriptStore {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "RubyCutsTests-\(UUID().uuidString)")
        let store = ScriptStore(directoryURL: dir)
        try store.ensureDirectory()
        return store
    }

    @Test func ignoresURLsThatAreNotScriptLinks() throws {
        let library = ScriptLibrary(store: try makeStore())
        #expect(!library.handleOpenURL(try #require(URL(string: "https://example.com"))))
        #expect(library.requestedScriptFileName == nil)
    }

    @Test func waitsForTheListToLoadThenSelectsTheScript() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        _ = try store.create(name: "weather", source: "")
        let library = ScriptLibrary(store: store)

        #expect(library.handleOpenURL(ScriptLink.url(forFileName: "weather.rb")))
        // Cold launch: nothing listed yet, so the request stays pending.
        #expect(library.takeRequestedScript() == nil)
        #expect(library.requestedScriptFileName == "weather.rb")

        library.refresh()
        #expect(library.takeRequestedScript()?.name == "weather")
        #expect(library.requestedScriptFileName == nil)
        // Taken once only.
        #expect(library.takeRequestedScript() == nil)
    }

    @Test func dropsARequestForAMissingScriptWithAnError() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.directoryURL) }
        _ = try store.create(name: "other", source: "")
        let library = ScriptLibrary(store: store)
        library.refresh()

        library.handleOpenURL(ScriptLink.url(forFileName: "gone.rb"))
        #expect(library.takeRequestedScript() == nil)
        #expect(library.requestedScriptFileName == nil)
        #expect(library.errorMessage?.contains("gone") == true)
    }
}
