# RubyCuts

RubyCuts is an open-source, universal Apple app (iOS, iPadOS, macOS) that lets you write, manage, and run Ruby code natively from Apple Shortcuts.

It's inspired by [Rubyist](https://rubyist.app), but aims to be actively maintained and to embed the full CRuby (MRI) environment instead of the limited `mruby` VM, giving you real standard library access (`csv`, `json`, `net/http`, ...) and the ability to pull in pure Ruby gems at runtime.

## Status

Early, pre-alpha. The app currently builds and runs, but none of the Ruby execution, Shortcuts integration, or script management features exist yet. Expect breaking changes.

## Requirements

- Xcode 26
- iOS 18+ / iPadOS 18+, or macOS 15+

## Building

RubyCuts embeds a statically-linked CRuby, built by a standalone script rather than as part of the Xcode build (it takes 10-20 minutes, which would make every `⌘B` miserable). Run this once before opening the project:

```sh
mise install
ruby scripts/build-cruby.rb
```

See [`docs/embedding-cruby.md`](docs/embedding-cruby.md) for what it does and why. With that done, clone the repo and open `RubyCuts.xcodeproj` in Xcode, or build from the command line:

```sh
xcodebuild -project RubyCuts.xcodeproj -scheme RubyCuts -destination 'platform=macOS' build
```

Swap the destination for an iOS Simulator to target iOS, e.g. `-destination 'platform=iOS Simulator,name=iPhone 17'`.

### Signing

Project-level settings pull `DEVELOPMENT_TEAM` from `Config/Local.xcconfig`, which is git-ignored so each contributor keeps their own. To build and run on a device:

```sh
cp Config/Local.xcconfig.sample Config/Local.xcconfig
# then edit Config/Local.xcconfig and set your team ID
```

Simulator and macOS builds work without this, since they don't require a signing team.

### Git hooks

There's an advisory `swift-format` lint that runs on staged files before each commit. It never blocks the commit, it just prints warnings. Enable it with:

```sh
git config core.hooksPath .githooks
```

## License

MIT, see [LICENSE](LICENSE).
