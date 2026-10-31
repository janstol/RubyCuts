# RubyCuts

RubyCuts is an open-source, universal Apple app (iOS, iPadOS, macOS) that lets you write, manage, and run Ruby code natively from Apple Shortcuts.

It's inspired by [Rubyist](https://rubyist.app), but aims to be actively maintained and to embed the full CRuby (MRI) environment instead of the limited `mruby` VM, giving you real standard library access (`csv`, `json`, `net/http`, ...) and the ability to pull in pure Ruby gems at runtime.

## Features

- **Real Ruby.** CRuby 3.4.9 (MRI) embedded in the app, with its standard library: `json`, `csv`, `yaml`, `net/http` over HTTPS, `openssl` and more.
- **Shortcuts actions.** "Run Inline Ruby" and "Run Ruby Script" take `ARGV` (a list), `STDIN` and `ENV` from the Shortcut and return `STDOUT` to the next action. A script that raises or writes to `STDERR` fails the Shortcut with Ruby's error message.
- **Script editor.** Syntax highlighting, a console with output, errors, backtrace and timing, a Stop button for runaway scripts, plus search, sort, rename and sample scripts to start from.
- **iCloud Drive sync.** Scripts live in a "RubyCuts" folder in iCloud Drive, so they sync between your devices and you can edit them in any editor. Without iCloud they're kept on the device.
- **Gems.** Search and install pure-Ruby gems from rubygems.org, dependencies included, and `require` them right away. `sqlite3` comes bundled. Gems with C extensions can't be installed (Apple doesn't allow loading downloaded native code).
- **Native bridge.** `Device::Clipboard` and `Device::Notification` let scripts read and write the clipboard and post notifications.
- **iPhone, iPad and Mac.** One universal app, with a menu bar, keyboard shortcuts and a Settings window on the Mac, and a built-in reference for the Ruby-to-Shortcuts contract.

## Status

Everything above works and is in daily use on Mac and iPhone. RubyCuts isn't in the App Store yet: submission is next, with Apple's rules on interpreted code (guideline 2.5.2) in mind.

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
