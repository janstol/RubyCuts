# Embedding CRuby

RubyCuts statically links a full CRuby (MRI) build into the app rather than a subset VM like `mruby`. This doc covers the pinned version, how to build and rebuild it, why the flags are what they are, and what's deliberately left out for now.

## Attribution

The configure flags and several of the workarounds below (especially the iOS-specific ones slated for slice 2) are ported from [xord/cruby](https://github.com/xord/cruby) (MIT license), which cross-compiles CRuby into an xcframework via CocoaPods. RubyCuts doesn't depend on it directly -- it's CocoaPods-only, Objective-C, and this project is SPM-only with zero third-party dependencies -- but its Rakefile is the reason the flags below aren't a guess.

## Pinned version

| | |
|---|---|
| Version | 3.4.9 |
| Source | `https://cache.ruby-lang.org/pub/ruby/3.4/ruby-3.4.9.tar.gz` |
| SHA256 | `7bb4d4f5e807cc27251d14d9d6086d182c5b25875191e44ab15b709cd7a7dd9c` |

Both live as constants at the top of `scripts/build-cruby.rb`, which downloads and verifies the tarball before building.

3.4.9 is the latest stable release as of this writing (no 3.4 has been superseded by a 3.5 release yet). Its minor version (3.4) matches the host Ruby pinned in `mise.toml`, which matters because CRuby's build needs a "base Ruby" to run its own generator scripts during the build; when the host Ruby's minor already matches the target, `--with-baseruby` and a separate native bootstrap build aren't necessary.

## Building

```sh
mise install                  # once, to get Ruby 3.4.x on PATH
ruby scripts/build-cruby.rb   # 10-20 minutes
```

This downloads and SHA256-verifies the tarball into `.build-cruby/src/`, configures and builds out-of-tree into `.build-cruby/<sdk>-<arch>/`, then copies the resulting static library and headers into `Vendor/CRuby/`. Both `.build-cruby/` and `Vendor/CRuby/` are git-ignored -- this is a build artifact, not something to commit.

The script is idempotent: each step (download, extract, configure+make, install) is skipped if its output already exists, so re-running it after it's already succeeded finishes in a couple seconds. Pass `--clean` to wipe `.build-cruby/` and `Vendor/CRuby/` and start over.

The Xcode project does **not** run this script as part of a normal build -- a CRuby build takes 10-20 minutes, and making every `⌘B` depend on it would make the project miserable to work in. Instead, the app target has a Run Script build phase, ordered before Compile Sources, that just checks `Vendor/CRuby/lib/macosx/libruby-static.a` exists and fails with a pointer to this script if it's missing.

## Bumping the version

1. Update `RUBY_VERSION_PIN` and `RUBY_VERSION_SHA256` in `scripts/build-cruby.rb`. Get the SHA256 from the release announcement at `https://www.ruby-lang.org/en/news/`, or compute it yourself: `curl -sSL <tarball-url> | shasum -a 256`.
2. `ruby scripts/build-cruby.rb --clean`
3. Re-run the verification steps below.

## Why the flags are what they are

```
MACOSX_DEPLOYMENT_TARGET=15.0 \
CFLAGS="-pipe -Os -fvisibility=hidden" \
./configure --prefix=<install> \
  --disable-shared --disable-dln --disable-install-doc \
  --with-static-linked-ext \
  --without-bigdecimal --without-readline --without-openssl --without-psych \
  --with-out-ext=bigdecimal*,readline*,openssl*,psych*
```

- `--disable-shared` -- we want a static archive to link into the app bundle, not a `.dylib` a sandboxed app can't load from an arbitrary path.
- `--disable-dln` -- disables Ruby's own dynamic-library loading (`dlopen`-based `require` of C extensions). The app never loads a `.so` at runtime; every extension it needs is compiled in statically.
- `--with-static-linked-ext` -- links C extensions (`zlib`, `stringio`, etc.) into the static archive itself instead of building them as separate loadable objects that `--disable-dln` would make unreachable.
- `--without-openssl --without-psych` -- **no TLS and no YAML in this slice.** This is what keeps slice 1 cheap: with no third-party static libraries (OpenSSL, libyaml) to cross-compile and merge, packaging is a plain `make install` plus a copy, and the `ar`-explode / `lipo`-merge machinery a real fat static lib would need never has to exist yet. `net/http` over TLS and `psych` come back in slice 3, once that merge step is built.
- `--without-bigdecimal --without-readline` -- neither is needed for evaluating expressions from Swift; `readline` in particular expects a real TTY, which doesn't exist in an app sandbox.
- `-fvisibility=hidden` -- keeps the archive's non-public symbols out of the app binary's exported symbol table.

The macOS arm64 target builds natively (no `--host` cross-compile flag), since the build machine's own architecture already matches: Apple Silicon Xcode running on Apple Silicon macOS. iOS builds need `--host=arm-apple-darwin` and several autoconf overrides for functions the platform doesn't expose -- that lands in slice 2 alongside the rest of the iOS-specific work.

## What's deliberately not here yet

- **No iOS.** The iOS-specific configure overrides (`ac_cv_func_{backtrace,system,syscall,__syscall,getentropy,dup3,pipe2}=no`, a stub `sys/vnode.h`, `--without-fiddle` for App Store review, `--host=arm-iphone-darwin`) are known from the xord/cruby recipe and land in slice 2.
- **No OpenSSL / libyaml**, as above -- `require 'net/http'` won't establish a TLS connection and `require 'yaml'` won't load. Slice 3.
- **No stdlib `.rb` files bundled.** `require 'json'`, `require 'csv'`, and friends won't work yet -- only core classes and methods that don't need a `.rb` file on `$LOAD_PATH`. Bundling `lib/ruby/3.4.0/` and wiring the load path is the very next slice.
- **No x86_64.** Intel Mac and Intel simulator support come with the fat-lib work in slice 2.

## Header layout

Ruby installs generic headers under `include/ruby-3.4.0/` and one arch-specific header, `include/ruby-3.4.0/<arch-triplet>/ruby/config.h`, in a sibling directory. `scripts/build-cruby.rb`'s `install_artifacts!` flattens both into a single `Vendor/CRuby/include/`, so `HEADER_SEARCH_PATHS` only needs one `-I` path. That works because slice 1 builds exactly one arch; see the `SEAM` comment in `Config/Shared.xcconfig` for what has to change once slice 2 adds more.

## Verifying a build

```sh
lipo -info Vendor/CRuby/lib/macosx/libruby-static.a   # => arm64
ls Vendor/CRuby/include/ruby/config.h
```
