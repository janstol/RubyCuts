# RubyCuts

RubyCuts is an open-source, universal Apple app (iOS, iPadOS, macOS) that lets you write, manage, and run Ruby code natively from Apple Shortcuts.

It's inspired by [Rubyist](https://rubyist.app), but aims to be actively maintained and to embed the full CRuby (MRI) environment instead of the limited `mruby` VM, giving you real standard library access (`csv`, `json`, `net/http`, ...) and the ability to pull in pure Ruby gems at runtime.

## Status

Pre-alpha, but the core loop works: CRuby 3.4.9 runs embedded on iOS, iPadOS, and macOS, scripts are stored and edited in the app, and both Shortcuts actions ("Run Inline Ruby", "Run Ruby Script") wire `ARGV`/`STDIN`/`ENV` in and `STDOUT`/`STDERR` back out. There's a small native bridge (`Device::Clipboard`, `Device::Notification`), pure-Ruby gem installs from rubygems.org (plus a bundled `sqlite3`), and a first-launch set of sample scripts with an in-app reference.

Not yet ready to ship: iCloud sync is blocked on a paid Apple Developer account, App Store submission (with guideline 2.5.2 on interpreted code in mind) hasn't been attempted, and a handful of correctness fixes from a code review are still open. Expect breaking changes.

## Requirements

- Xcode 27
- iOS 26+ / iPadOS 26+, or macOS 26+

## Building

RubyCuts embeds a statically-linked CRuby, built by a standalone script rather than as part of the Xcode build (it takes 10-20 minutes, which would make every `⌘B` miserable). Run this once before opening the project:

```sh
mise install
mise run cruby
```

See [`docs/embedding-cruby.md`](docs/embedding-cruby.md) for what it does and why. With that done, clone the repo and open `RubyCuts.xcodeproj` in Xcode, or build from the command line with the [mise](https://mise.jdx.dev) tasks in `mise.toml`:

```sh
mise run build          # macOS
mise run build:ios      # iOS Simulator (set IOS_SIM to pick another device)
mise run test           # unit tests on macOS
mise run test RubyCutsTests/ScriptStoreTests   # one suite
mise run test:ios       # unit and UI tests on the iOS Simulator
mise run lint           # swift-format lint on changed Swift files
```

`mise tasks` lists them all. Each is a thin wrapper around `xcodebuild` or `swift format`, so you can read the exact command in `mise.toml`.

### Signing

Project-level settings pull `DEVELOPMENT_TEAM` from `Config/Local.xcconfig`, which is git-ignored so each contributor keeps their own. To build and run on a device:

```sh
cp Config/Local.xcconfig.sample Config/Local.xcconfig
# then edit Config/Local.xcconfig and set your team ID
```

Simulator builds work without this. macOS builds need it too, because the iCloud entitlement requires a provisioning profile: the Mac has to be registered in your developer account, and command-line builds need `-allowProvisioningUpdates` (the mise tasks pass it).

### Git hooks

There's an advisory `swift-format` lint that runs on staged files before each commit. It never blocks the commit, it just prints warnings. Enable it with:

```sh
mise run hooks
```

## License

MIT, see [LICENSE](LICENSE).
