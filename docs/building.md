# Building RubyCuts

## Requirements

- Xcode 27
- [mise](https://mise.jdx.dev), which installs the Ruby used to build CRuby and runs the project's tasks
- A Mac to build on; the app runs on iOS 26+ / iPadOS 26+ and macOS 26+

## Building

RubyCuts embeds a statically-linked CRuby, built by a standalone script rather than as part of the Xcode build (it takes 10-20 minutes, which would make every `⌘B` miserable). Run this once before opening the project:

```sh
mise install
mise run cruby
```

See [`embedding-cruby.md`](embedding-cruby.md) for what it does and why. With that done, clone the repo and open `RubyCuts.xcodeproj` in Xcode, or build from the command line with the [mise](https://mise.jdx.dev) tasks in `mise.toml`:

```sh
mise run build          # macOS
mise run build:ios      # iOS Simulator (set IOS_SIM to pick another device)
mise run test           # unit tests on macOS
mise run test RubyCutsTests/ScriptStoreTests   # one suite
mise run test:ios       # unit and UI tests on the iOS Simulator
mise run lint           # swift-format lint on changed Swift files
mise run install:device # "RubyCuts Dev" on a connected iPhone, next to the App Store/TestFlight app
```

`mise tasks` lists them all. Each is a thin wrapper around `xcodebuild` or `swift format`, so you can read the exact command in `mise.toml`.

## Signing

Project-level settings pull `DEVELOPMENT_TEAM` from `Config/Local.xcconfig`, which is git-ignored so each contributor keeps their own. To build and run on a device:

```sh
cp Config/Local.xcconfig.sample Config/Local.xcconfig
# then edit Config/Local.xcconfig and set your team ID
```

Simulator builds work without this. macOS builds need it too, because the iCloud entitlement requires a provisioning profile: the Mac has to be registered in your developer account, and command-line builds need `-allowProvisioningUpdates` (the mise tasks pass it).

## Git hooks

There's an advisory `swift-format` lint that runs on staged files before each commit. It never blocks the commit, it just prints warnings. Enable it with:

```sh
mise run hooks
```
