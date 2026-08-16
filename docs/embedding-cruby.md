# Embedding CRuby

RubyCuts statically links a full CRuby (MRI) build into the app rather than a subset VM like `mruby`. This doc covers the pinned version, how to build and rebuild it, why the flags are what they are, and what's deliberately left out for now.

## Attribution

The configure flags and several of the workarounds below (especially the iOS-specific ones) are ported from [xord/cruby](https://github.com/xord/cruby) (MIT license), which cross-compiles CRuby into an xcframework via CocoaPods. RubyCuts doesn't depend on it directly -- it's CocoaPods-only, Objective-C, and this project is SPM-only with zero third-party dependencies -- but its Rakefile is the reason the flags below aren't a guess.

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
ruby scripts/build-cruby.rb   # 30-60 minutes, three targets: macOS, iOS device, iOS simulator
```

This downloads and SHA256-verifies the tarball into `.build-cruby/src/`, configures and builds out-of-tree into `.build-cruby/<sdk>-<arch>/`, then copies the resulting static library and headers into `Vendor/CRuby/`. Both `.build-cruby/` and `Vendor/CRuby/` are git-ignored -- this is a build artifact, not something to commit.

The script is idempotent: each step (download, extract, configure+make, install) is skipped if its output already exists, so re-running it after it's already succeeded finishes in a couple seconds. Pass `--clean` to wipe `.build-cruby/` and `Vendor/CRuby/` and start over.

The Xcode project does **not** run this script as part of a normal build -- building all three targets takes 30-60 minutes, and making every `⌘B` depend on it would make the project miserable to work in. Instead, the app target has a Run Script build phase, ordered before Compile Sources, that just checks `Vendor/CRuby/lib/$(PLATFORM_NAME)/libruby-static.a` exists for whatever platform is currently building and fails with a pointer to this script if it's missing.

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
  --without-bigdecimal --without-readline --without-fiddle \
  --with-out-ext=bigdecimal*,readline*,fiddle* \
  --with-openssl-dir=<openssl-install> --with-libyaml-dir=<libyaml-install>
```

- `--disable-shared` -- we want a static archive to link into the app bundle, not a `.dylib` a sandboxed app can't load from an arbitrary path.
- `--disable-dln` -- disables Ruby's own dynamic-library loading (`dlopen`-based `require` of C extensions). The app never loads a `.so` at runtime; every extension it needs is compiled in statically.
- `--with-static-linked-ext` -- links C extensions (`zlib`, `stringio`, etc.) into the static archive itself instead of building them as separate loadable objects that `--disable-dln` would make unreachable.
- `--with-openssl-dir=<openssl-install> --with-libyaml-dir=<libyaml-install>` -- point the `openssl` and `psych` extconfs at the per-target third-party static installs built by `build_openssl!`/`build_libyaml!` (see below). Ruby's configure forwards every `--with-*` arg (stored in `ac_configure_args`) to each ext's extconf, where mkmf's `dir_config("openssl")` / `dir_config("libyaml")` reads them, so the extconfs find these builds instead of probing the host. This is what brings TLS (`net/http` over HTTPS) and YAML (`require 'yaml'` via psych) online; the resulting `libssl.a`/`libcrypto.a`/`libyaml.a` are merged into `libruby-static.a` (see `merge_static_extensions!`).
- `--without-bigdecimal --without-readline` -- neither is needed for evaluating expressions from Swift; `readline` in particular expects a real TTY, which doesn't exist in an app sandbox.
- `--without-fiddle` -- `fiddle` is Ruby's FFI/`dlopen` binding. On iOS, a shipped app that can `dlopen` and call arbitrary native code fails App Store review; dropped for every target (including macOS) so all three build from one flag set instead of macOS quietly carrying a capability iOS can't have.
- `-fvisibility=hidden` -- keeps the archive's non-public symbols out of the app binary's exported symbol table.

The macOS arm64 target builds natively (no `--host` cross-compile flag), since the build machine's own architecture already matches: Apple Silicon Xcode running on Apple Silicon macOS. The two iOS targets are real cross-compiles and need more:

```
IPHONEOS_DEPLOYMENT_TARGET=18.0 \
CFLAGS="-pipe -Os -fvisibility=hidden -target arm64-apple-ios18.0 -isysroot <iphoneos SDK path> -I<stub-include>" \
LDFLAGS="-target arm64-apple-ios18.0 -isysroot <iphoneos SDK path>" \
ac_cv_func_backtrace=no ac_cv_func_system=no ac_cv_func_syscall=no ac_cv_func___syscall=no \
ac_cv_func_getentropy=no ac_cv_func_dup3=no ac_cv_func_pipe2=no \
./configure --prefix=<install> --host=aarch64-apple-darwin --with-baseruby=<host ruby> \
  ...same flags as macOS above...
```

(the simulator row is identical but for `-target arm64-apple-ios18.0-simulator`, the `iphonesimulator` SDK path, and a different install destination)

- `--host=aarch64-apple-darwin` -- tells autoconf this is a cross-compile, so it can't run test binaries and has to trust its probes (or the `ac_cv_func_*` overrides below) instead of executing them.
- `-target <triple> -isysroot <sdk path>` on both `CFLAGS` and `LDFLAGS` -- the compile step needs the target triple and iOS sysroot instead of the host's default; `LDFLAGS` carries the same because `configure`'s own link probes (`AC_CHECK_FUNC`-style checks that compile-and-link a tiny probe program) need to resolve against the iOS SDK too, not just the final `make` link.
- `--with-baseruby=<host ruby>` -- a cross-compile can't run the CRuby binary it's building to generate `.rb`-derived headers and tables partway through the build, so it needs a working native Ruby to do that job instead. `check_host_ruby!` in `scripts/build-cruby.rb` guarantees the host Ruby's minor version matches the target before this is used.
- **Stub `sys/vnode.h`** -- the iOS SDKs don't ship this header. `dir.c:100` includes it unconditionally under `#ifdef __APPLE__`, with no autoconf guard, so the build hard-fails without it. The stub can't be empty: `dir.c:2252-2254` compares against `VREG`/`VDIR`/`VLNK` (`enum vtype`), and `dir.c:211-212`/`3784` compare against `VT_HFS`/`VT_CIFS` (`enum vtagtype`) -- both enums have to be redeclared, and their member ordering has to match the macOS SDK's header exactly, since those values get compared against live `getattrlist` output at runtime. (`fsobj_tag_t` itself doesn't need redeclaring -- it's a plain `u_int32_t` typedef in `sys/attr.h`, which the iOS SDKs do ship.) `write_vnode_stub!` in `scripts/build-cruby.rb` generates the stub per target into `.build-cruby/<target>/stub-include/sys/vnode.h`, added to `CFLAGS` via `-I`.
- **`ac_cv_func_*=no` overrides** -- `backtrace`, `system`, `syscall`, `__syscall`, `getentropy`, `dup3`, `pipe2` are present in the iOS SDK headers, so autoconf's normal probing finds them and Ruby then emits calls to them. Some are unavailable at link time, some are private/entitlement-gated, and calling them can fail App Store review even where they link. This list is ported as-is from the [xord/cruby](https://github.com/xord/cruby) recipe (see Attribution above); it hasn't been individually re-verified against the current iOS SDK, so treat it as the known-good starting point rather than a minimal set -- trimming it is a plausible follow-up, but only worth doing against a green test run to trim against.

Two more fixes came up cross-compiling against the current iOS 26 SDKs that aren't in the xord/cruby recipe (it targets an older Ruby and SDK):

- **`vm_dump.c`'s `system()` patch.** `rb_vm_bugreport`'s `RUBY_ON_BUG` debug hook calls `system()` unconditionally -- unlike everywhere else CRuby gates a call behind a `HAVE_*` check (`HAVE_BACKTRACE` guards the near-identical helper one function above, in the same file), this one isn't gated, so it fails to compile once `ac_cv_func_system=no` above removes `HAVE_SYSTEM`. `patch_vm_dump_system_guard!` in `scripts/build-cruby.rb` wraps it in `#ifdef HAVE_SYSTEM` before configuring, once per full source checkout (idempotent, and a no-op on macOS, where `HAVE_SYSTEM` stays defined).
- **Bundled gems with a native C extension don't link on iOS at all.** `debug`, `racc`, `nkf`, `rbs`, and `syslog` -- the `bundled_gems`-listed runtime gems with an `ext/`, distinct from `bigdecimal` which is excluded via `--without-bigdecimal` above for an unrelated reason -- each build a `.bundle` the same way every Ruby C extension does: unresolved core VM symbols (`rb_eArgError` and the like), trusting the process that `dlopen()`s it to resolve them at load time. On macOS that trust is spelled `-undefined dynamic_lookup`; Apple's iOS linker refuses the flag outright for any binary, so every one of these fails at link with a page of undefined symbols. None of them are needed by RubyCuts -- `Vendor/CRuby` only ever takes the static lib and headers, never an installed gems tree -- so `patch_bundled_gems!` strips their lines from `gems/bundled_gems` before extraction, for every target, and sweeps any stale `.bundle/gems`/`.bundle/extensions` output a build that failed on one of these before this exclusion existed may have left behind.

### OpenSSL + libyaml cross-compile (TLS + YAML)

Two third-party C libraries are cross-compiled per target and merged into `libruby-static.a` so `require 'openssl'` (TLS for `net/http`) and `require 'yaml'` (psych's libyaml backend) work on all three platforms. Both are pinned at the top of `scripts/build-cruby.rb` alongside the Ruby pin, downloaded + SHA256-verified into `.build-cruby/src/`:

| | |
|---|---|
| OpenSSL | 3.6.3 -- `https://github.com/openssl/openssl/releases/download/openssl-3.6.3/openssl-3.6.3.tar.gz` |
| libyaml | 0.2.5 -- `https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz` |

The SHA256s are verified against the official sources (OpenSSL against the `.sha256` published alongside the release; libyaml, which publishes no sibling checksum, cross-checked against the sha512 in Arch Linux's libyaml PKGBUILD), not a third-party repo -- re-verify on bump.

`build_libyaml!` and `build_openssl!` run per target, before `configure_and_make!`, and are idempotent (skip if the install dir already holds the built `.a`). Each builds out-of-tree in its own build dir so the three targets never share configure state. libyaml is autoconf (`./configure --enable-static --disable-shared`); the iOS cross-compiles point `CC` at the SDK via `xcrun --sdk <sdk> cc -arch arm64` and carry `-target <triple> -isysroot <sdk>` on `CFLAGS`/`LDFLAGS`, the same triple/sysroot the Ruby cross-compile uses. OpenSSL uses its own Perl `Configure` with the built-in Apple targets -- `darwin64-arm64-cc` (macOS), `ios64-xcrun` (device), `iossimulator-xcrun` (simulator) -- which drive clang via `xcrun -sdk <sdk> cc` and auto-select the SDK. Those targets don't pin a deployment target, so `CFLAGS=-target <triple>` is passed (OpenSSL's `Configure` appends the `CFLAGS` env to the target's flags), pinning arch + min iOS version; the native macOS build needs no `-target`. `no-shared no-tests no-apps` build only the libraries (no CLI, no tests), and `make install_sw` installs `libssl.a`/`libcrypto.a` + headers, skipping docs/engines. If a future Xcode's SDK makes the built-in xcrun targets misbehave, the fallback is a custom target file inheriting from `ios64-xcrun`/`darwin64-arm64-cc` with an explicit `-isysroot` (mirroring xord/cruby's `OSSL_CUSTOM_CONF`).

`patch_psych_extconf!` neutralizes the unconditional `pkg_config('yaml-0.1')` call in `ext/psych/extconf.rb` (run once per checkout, idempotent). Without it, a build machine with `pkg-config` plus a host Homebrew libyaml installed would let that `pkg_config` pick up the host (macOS-arch) libyaml and contaminate the iOS cross-compile with the wrong arch; with it gone, the `dir_config('libyaml')` + `find_header`/`find_library` path driven by `--with-libyaml-dir` is the only one taken. The openssl extconf needs no such patch -- it already skips `pkg_config("openssl")` when `--with-openssl-dir` is given (`dir_config_given` gates it).

`merge_static_extensions!` folds `libssl.a`, `libcrypto.a`, and `libyaml.a` into `libruby-static.a` by appending them to the same `libtool -static -filelist` as the Ruby ext/enc archives. Because the third-party libs live *inside* `libruby-static.a`, the existing `-Wl,-force_load,...libruby-static.a` in `Config/Shared.xcconfig` pulls them in -- no new link flag in the common case. (Contingency, only if `libtool` errors on duplicate member names: the explode-rename-rearchive method -- extract every archive, rename colliding `.o`s with a numeric prefix, exclude `dmyext.o`/`dmyenc.o`, then `ar -crs` everything into the final archive. Not used today.) If the app link ever fails with undefined OpenSSL symbols, add `-framework Security` (and/or `-framework CoreFoundation`) to `OTHER_LDFLAGS` -- verify before adding.

### `--with-static-linked-ext` doesn't actually reach `lib*-static.a`

Discovered while wiring up `require 'stringio'` and friends in the stdlib-bundling slice, by probing the built archive with `nm` rather than trusting the flag's name: `--with-static-linked-ext` links every statically-linked C extension (`stringio`, `json/ext`, `socket`, `date_core`, `strscan`, ...) into its own per-extension archive (`ext/<name>/<name>.a`) and generates `ext/extinit.c` to register them all with the VM's `require` machinery. But the generated `Makefile`'s object list for `lib*-static.a` (`$(LIBRUBY_A_OBJS)`, i.e. `$(OBJS)`) never includes them -- only the final `ruby` executable's own link recipe does. Left alone, `lib*-static.a` ships `dmyext.o`'s empty `Init_ext()` stub instead of the real one, so `require` of any statically-linked extension fails with `cannot load such file`, and the equivalent `dmyenc.o` stub means non-ASCII encodings (`Encoding.find("Shift_JIS")` and friends) aren't registered either.

`merge_static_extensions!` in `scripts/build-cruby.rb` fixes this after `make install`: it drops the two stub objects from the installed static lib and merges in the real ones (`ext/extinit.o` + every `ext/**/*.a`, `enc/encinit.o` + `enc/libenc.a` + `enc/libtrans.a`) with `libtool -static`, which -- unlike plain `ar` -- flattens nested `.a` members into the output archive instead of embedding them as archive-in-archive members `ar` can't see into. The same step folds in the third-party `libssl.a`/`libcrypto.a`/`libyaml.a` (see the OpenSSL + libyaml section below). It's idempotent (checks for `dmyext.o` in the archive before doing anything) and runs for every target, every time the script runs, independent of whether `configure_and_make!` decided a target was already built.

## Completing VM boot: `ruby_options()`, not bare `ruby_init()`

`rubycuts_init()` (`RubyCuts/Ruby/rubycuts_shim.c`) calls `RUBY_INIT_STACK; ruby_init();` same as before, but that alone is not a complete boot -- `ruby_init()` only runs `Init_BareVM` plus the core-class `rb_call_inits()` list. It never runs `Init_ext()` (registering every statically-linked C extension so `require` can find it -- see above), never loads the compiled builtin iseqs, never sets up the non-ASCII encoding database, and never seeds `$LOAD_PATH`. All of that lives in `ruby_opt_init()`, reachable only through `ruby_options()`, CRuby's command-line option processor.

`rubycuts_init()` calls `ruby_options()` with a synthetic, writable argv equivalent to `ruby --disable-gems -e ''`:

- `argv[0]` is `NULL`, and every other element points at a writable (non-literal) buffer -- `ruby_options()` mutates argv in place (`ruby_setproctitle()`, `$0=`), which is undefined behavior against a string literal's read-only storage.
- `-e ''` makes `ruby_options()` run the full boot sequence without there being a script to actually execute; its return value (an opaque node for `ruby_run_node()`) is discarded, since there's nothing in it worth running.
- `--disable-gems` skips RubyGems bootstrap entirely -- not needed, since plain `Kernel#require` against `$LOAD_PATH` is sufficient once the stdlib and bundled gems are flattened into one directory (see below).

`ruby_options()` also runs `ruby_init_loadpath()`, which seeds `$LOAD_PATH` from `ruby_exec_prefix`, a compile-time constant baked into `verconf.h` at cross-compile time -- it points at this machine's `.build-cruby/.../install`, present on the dev Mac and absent on a device or simulator. `rubycuts_init()` throws that away on purpose: right after `ruby_options()` returns, it clears `$LOAD_PATH` and pushes the one path that actually ships in the app bundle (see below). This is also why relying on `ruby_init_loadpath()`'s output directly, or passing `-I<path>` in argv instead of the explicit clear-and-push, wouldn't work -- either leaves the stale dev-machine entries in place as a shadowing hazard instead of removing them, which would let `require` keep working on macOS via leftover paths while silently broken on device. `RubyRuntimeTests.loadPathIsExactlyTheBundledStdlib` exists specifically to catch that failure mode.

## Bundling the stdlib and wiring `$LOAD_PATH`

`Vendor/CRuby/stdlib/` is `lib/ruby/3.4.0/` from the CRuby install, minus a deny-list, plus two bundled gems flattened in alongside it. `install_stdlib!` in `scripts/build-cruby.rb` builds it once (not per target) after confirming, with a SHA256 digest, that all three target installs' stdlib trees are byte-identical -- turning what was previously just an assumption into a build-time assertion.

`EXCLUDED_STDLIB_ENTRIES` (the deny-list) leaves out:

- `bundler`, `rubygems` -- not needed; `rubycuts_init()` boots with `--disable-gems`, and plain `Kernel#require` against `$LOAD_PATH` is enough.
- `irb`, `reline`, `readline.rb` -- no TTY in an app sandbox.
- `did_you_mean`, `error_highlight`, `syntax_suggest` -- REPL/CLI error-message niceties, not needed for running a script.
- `rdoc`, `prism` (the standalone gem copy; the C-ext `prism` core extension is unaffected) -- not needed for running scripts.
- `mkmf.rb` -- a C-extension build tool, meaningless without a compiler on-device.
- `un.rb` -- a command-line coreutils shim, not a library.
- `ruby_vm` -- `RubyVM::*` introspection helpers this app has no use for.
- The per-target arch subdirectory (e.g. `arm64-darwin25/`), whose only content is `rbconfig.rb`. Detected by content (the one child containing `rbconfig.rb`), not a hardcoded name, so a future Ruby version's differently-named arch subdirectory gets caught rather than silently shipped or silently skipped. The original can't ship as-is (it embeds this machine's absolute `--prefix`/`--host` build paths); `sanitize_rbconfig!` writes a sanitized copy to the stdlib root instead -- see below.

`yaml` and `yaml.rb` are **not** on the deny-list anymore: psych is now built (libyaml merged in -- see the OpenSSL + libyaml section), so `require 'yaml'` resolves.

`INCLUDED_BUNDLED_GEMS` (`csv`, `base64`) are copied in from `lib/ruby/gems/3.4.0/gems/<gem>-*/lib/`, flattened alongside the stdlib -- `json`, `fileutils`, and `net/http` are already "default gems" and ship as part of `lib/ruby/3.4.0/` itself, no separate step needed.

**Sanitizing `rbconfig.rb` (the `resolv`/`net/http`/`logger` unblock).** The per-target arch subdirectory's `rbconfig.rb` embeds this machine's absolute `--prefix`/`--host` build paths, so it can't ship as-is. But excluding it outright has a wider blast radius than just `require 'rbconfig'`: besides the obviously-named case (`require 'logger'`, which needs it directly at `logger.rb:15`), `resolv.rb`'s top-level `WINDOWS` constant does `RUBY_PLATFORM =~ /mswin|cygwin|.../ || RbConfig::CONFIG['host_os'] =~ /mswin/` -- on any non-Windows platform the left side never short-circuits it, so loading `resolv` always touches `RbConfig` and raises `NameError` at `require` time. `resolv` is itself required by `net/http`, so without a fix `require 'net/http'` fails outright at load, before it ever gets near a socket.

`sanitize_rbconfig!` in `scripts/build-cruby.rb` resolves this by shipping a sanitized copy at the stdlib root (the one `$LOAD_PATH` entry, so `require 'rbconfig'` finds it). It's an explicit string rewrite, not a relocation: the original's `TOPDIR` line is `File.dirname(__FILE__).chomp!("/lib/ruby/3.4.0/<arch>")`, so once the file is moved to the stdlib root `__FILE__` no longer ends in that suffix, `chomp!` returns nil, `TOPDIR` is nil, and `CONFIG["prefix"]` falls back to `DESTDIR + "<dev path>"` -- relocation alone would therefore ship the dev-machine install path. The rewrite replaces that dev prefix with a neutral token (`/usr/local`) everywhere it appears (`prefix`, `RUBY_EXEC_PREFIX`, `configure_args`, and any `$(prefix)`-derived value `RbConfig.expand` resolves at load time), and swaps Homebrew's GNU coreutils (`ginstall`/`gmkdir`) for the plain BSD tools (`install`/`mkdir`) the app sandbox actually has. The `host`/`target`/`build`/`arch` family is left untouched -- it carries no absolute paths, and `host_os` (`darwin25`) is exactly what makes `resolv`'s `WINDOWS` check resolve to non-Windows on every platform. The full `RbConfig.expand` / `MAKEFILE_CONFIG` / `fire_update!` machinery stays intact, so the whole `RbConfig` surface stays available to any consumer. A build-time guard aborts if the dev prefix or any `/opt/homebrew` path survives the rewrite. `RubyRuntimeTests.requiresNetHTTP` and `requiresLogger` lock in the fix; `loadPathIsExactlyTheBundledStdlib` still passes (the sanitized file is added at the existing root, not a new `$LOAD_PATH` entry).

`rubycuts_init()` locates the bundled resource via `Bundle.main.resourceURL` (`RubyRuntime.swift`) -- `RubyCuts.app/Contents/Resources/stdlib` on macOS, `RubyCuts.app/stdlib` on iOS; `RubyCutsTests` is app-hosted (`TEST_HOST`/`BUNDLE_LOADER`), so `Bundle.main` resolves the same way during a test run. `Vendor/CRuby/stdlib/` is bundled into the app target as a folder reference (`RubyCuts.xcodeproj`'s `PBXFileReference` with `lastKnownFileType = folder`) rather than a Run Script `rsync` -- the project already has `ENABLE_USER_SCRIPT_SANDBOXING = YES`, which would deny a script phase read access to the ~130 files under `$SRCROOT` with no practical `inputPaths` declaration; Copy Bundle Resources is a native build-system task and unaffected.

## What's deliberately not here yet

**No x86_64, ever.** This isn't a deferred slice -- RubyCuts targets Apple Silicon only. `ARCHS = arm64` in `Config/Shared.xcconfig` enforces this at the project level, so an Intel Mac or an Intel simulator destination won't build. `TARGETS` in `scripts/build-cruby.rb` should never grow an x86_64 row.

## Header layout

Ruby installs generic headers under `include/ruby-3.4.0/` and one arch-specific header, `include/ruby-3.4.0/<arch-triplet>/ruby/config.h`, in a sibling directory. `scripts/build-cruby.rb`'s `install_artifacts!` flattens both, per target, into `Vendor/CRuby/include/<platform>/` -- one complete header tree per SDK (`macosx`, `iphoneos`, `iphonesimulator`), matching the per-SDK `Vendor/CRuby/lib/<platform>/libruby-static.a` layout. `<platform>` is exactly Xcode's `PLATFORM_NAME`, so `HEADER_SEARCH_PATHS` and `OTHER_LDFLAGS` in `Config/Shared.xcconfig` each need only one `$(PLATFORM_NAME)`-parameterized line instead of one row per SDK.

## Verifying a build

```sh
for p in macosx iphoneos iphonesimulator; do
  lipo -info Vendor/CRuby/lib/$p/libruby-static.a   # => arm64, for all three
  ls Vendor/CRuby/include/$p/ruby/config.h
  nm -g Vendor/CRuby/lib/$p/libruby-static.a | grep -c " T _Init_stringio$"  # => 1, for all three
  nm -g Vendor/CRuby/lib/$p/libruby-static.a | grep -c " T _Init_openssl$"  # => 1, for all three
  nm -g Vendor/CRuby/lib/$p/libruby-static.a | grep -c " T _Init_psych$"    # => 1, for all three
done
ls Vendor/CRuby/stdlib | head   # sanity: csv.rb, base64.rb present; no rdoc/, bundler/, rubygems/
ls Vendor/CRuby/stdlib/yaml.rb  # present now (psych is built); was excluded pre-slice-3
```

`vtool -show-build-version` on a member object of each archive confirms the platform each was actually built for (`MACOS` / `IOS` / `IOSSIMULATOR`) -- the check that catches a simulator build that silently picked up the device triple. The `Init_stringio` check confirms `merge_static_extensions!` actually replaced the `dmyext.o` stub; the `Init_openssl`/`Init_psych` checks confirm the openssl and psych extensions built and were merged in (without them, `require 'openssl'`/`require 'yaml'` raise `cannot load such file`) -- see above.

Beyond the artifact check, `RubyRuntimeTests` (including `reportsRubyVersion`, the test that actually boots the VM and evals, and `loadPathIsExactlyTheBundledStdlib`, the test that would catch a dev-machine-only pass) has run and passed on all three real destinations: macOS, iOS Simulator, and a physical iPhone -- not just a `generic/platform=iOS` unsigned build. A physical device needs a signing team (`Config/Local.xcconfig`, see `Local.xcconfig.sample`) and `-allowProvisioningUpdates` on the `xcodebuild` invocation to let Xcode generate the test-runner's provisioning profile automatically:

```sh
xcodebuild -project RubyCuts.xcodeproj -scheme RubyCuts \
  -destination 'platform=iOS,name=<your device name>' \
  -allowProvisioningUpdates \
  test -only-testing:RubyCutsTests
```

Building all three targets takes roughly 30-60 minutes.
