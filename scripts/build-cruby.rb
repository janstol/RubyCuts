#!/usr/bin/env ruby
# frozen_string_literal: true

# Downloads, verifies, and builds a statically-linked CRuby for embedding in RubyCuts, then installs the resulting library and headers into Vendor/CRuby/. See docs/embedding-cruby.md for the full rationale and the attribution to xord/cruby, whose Rakefile this recipe is ported from.
#
# Usage:
#   ruby scripts/build-cruby.rb          # build (skips steps already done)
#   ruby scripts/build-cruby.rb --clean  # wipe .build-cruby/ and Vendor/CRuby/ first

require "digest"
require "fileutils"
require "open-uri"
require "open3"

ROOT = File.expand_path("..", __dir__)
BUILD_DIR = File.join(ROOT, ".build-cruby")
SRC_DIR = File.join(BUILD_DIR, "src")
VENDOR_DIR = File.join(ROOT, "Vendor", "CRuby")
STDLIB_DEST = File.join(VENDOR_DIR, "stdlib")

RUBY_VERSION_PIN = "3.4.9"
RUBY_VERSION_SHA256 = "7bb4d4f5e807cc27251d14d9d6086d182c5b25875191e44ab15b709cd7a7dd9c"
RUBY_SERIES = RUBY_VERSION_PIN.split(".")[0, 2].join(".") # "3.4", the cache.ruby-lang.org series dir
RUBY_ABI_VERSION = "#{RUBY_SERIES}.0" # "3.4.0", the header dir name CRuby installs under

TARBALL_URL = "https://cache.ruby-lang.org/pub/ruby/#{RUBY_SERIES}/ruby-#{RUBY_VERSION_PIN}.tar.gz"
TARBALL_PATH = File.join(SRC_DIR, "ruby-#{RUBY_VERSION_PIN}.tar.gz")
SOURCE_DIR = File.join(SRC_DIR, "ruby-#{RUBY_VERSION_PIN}")

# OpenSSL (TLS for net/http) and libyaml (the C backend psych loads for
# `require 'yaml'`). Both are cross-compiled per target and merged into
# libruby-static.a -- see build_openssl!/build_libyaml! and
# merge_static_extensions!. SHA256s verified against the official sources:
# OpenSSL against the .sha256 published alongside the release (openssl.org
# redirects to the GitHub release asset), libyaml cross-checked against the
# sha512 in Arch Linux's libyaml PKGBUILD (libyaml publishes no sibling
# checksum). Do not trust a third-party repo for these -- re-verify on bump.
OPENSSL_VERSION_PIN = "3.6.3"
OPENSSL_SHA256 = "243a86649cf6f23eeb6a2ff2456e09e5d77dd9018a54d3d96b0c6bdd6ba6c7f1"
OPENSSL_TARBALL_URL = "https://github.com/openssl/openssl/releases/download/openssl-#{OPENSSL_VERSION_PIN}/openssl-#{OPENSSL_VERSION_PIN}.tar.gz"
OPENSSL_TARBALL_PATH = File.join(SRC_DIR, "openssl-#{OPENSSL_VERSION_PIN}.tar.gz")
OPENSSL_SOURCE_DIR = File.join(SRC_DIR, "openssl-#{OPENSSL_VERSION_PIN}")

LIBYAML_VERSION_PIN = "0.2.5"
LIBYAML_SHA256 = "c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4"
LIBYAML_TARBALL_URL = "https://github.com/yaml/libyaml/releases/download/#{LIBYAML_VERSION_PIN}/yaml-#{LIBYAML_VERSION_PIN}.tar.gz"
LIBYAML_TARBALL_PATH = File.join(SRC_DIR, "yaml-#{LIBYAML_VERSION_PIN}.tar.gz")
LIBYAML_SOURCE_DIR = File.join(SRC_DIR, "yaml-#{LIBYAML_VERSION_PIN}")

# sqlite3 -- the one C-extension gem RubyCuts ships pre-compiled, since a
# downloaded C extension can never be dlopen()ed under App Store W^X rules
# (see docs/embedding-cruby.md). Two pins, not one: the SQLite C library
# itself (compiled straight into libruby-static.a by build_sqlite!, from the
# amalgamation -- not the SDK's own libsqlite3, which is a different, often
# older, build) and the sqlite3 Ruby gem (whose ext/sqlite3 C sources feed a
# statically-linked extension via install_sqlite3_ext_sources!, and whose
# lib/ ships in Vendor/CRuby/stdlib/ via install_sqlite3_ruby_lib!).
#
# The SQLite version and SHA256 aren't chosen independently -- they're
# lifted verbatim from the sqlite3 gem's own dependencies.yml pin, whose
# comment records that this SHA256 was cross-checked against sqlite.org's
# own published SHA3-256 for the same tarball
# (025328da165109f48abccc6e7478508060804412bed2bd81d47e98ba1b72983b) --
# the same "don't trust a lone hash" discipline as the OpenSSL/libyaml pins
# above.
SQLITE_VERSION_PIN = "3.53.2"
SQLITE_TARBALL_SHA256 = "588ad51949419a56ebe81fe56193d510c559eb94c9a57748387860b5d3069316"
SQLITE_TARBALL_URL = "https://sqlite.org/2026/sqlite-autoconf-3530200.tar.gz"
SQLITE_TARBALL_PATH = File.join(SRC_DIR, "sqlite-autoconf-3530200.tar.gz")
SQLITE_SOURCE_DIR = File.join(SRC_DIR, "sqlite-autoconf-3530200")

# The latest non-prerelease `platform: "ruby"` sqlite3 gem version as of this
# writing. SHA256 is rubygems.org's own published `sha` for this version
# (from https://rubygems.org/api/v1/versions/sqlite3.json) -- the same value
# RubyGemsAPI/GemInstaller verify a downloaded gem against at runtime, so
# this pin is checked the identical way an app-installed gem would be.
SQLITE3_GEM_VERSION_PIN = "2.9.6"
SQLITE3_GEM_SHA256 = "956fe606956420d04ac7157d3ace620c8caba2135b2e05c76e483493da24d08e"
SQLITE3_GEM_URL = "https://rubygems.org/downloads/sqlite3-#{SQLITE3_GEM_VERSION_PIN}.gem"
SQLITE3_GEM_PATH = File.join(SRC_DIR, "sqlite3-#{SQLITE3_GEM_VERSION_PIN}.gem")
# Where extract_sqlite3_gem! unpacks the gem's data.tar.gz payload -- a
# .gem's own top-level tar has no version in its member names, so this dir
# isn't named after SQLITE3_GEM_VERSION_PIN the way SQLITE_SOURCE_DIR is
# named after SQLITE_VERSION_PIN.
SQLITE3_GEM_SOURCE_DIR = File.join(SRC_DIR, "sqlite3-gem")

# Mozilla CA bundle (curl's cacert.pem) shipped as OpenSSL's trust store.
# OpenSSL's compiled-in --openssldir is a build-machine path that doesn't exist
# on device, so OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.set_default_paths
# (run when openssl/ssl.rb loads) finds no roots and every HTTPS request fails
# with "unable to get local issuer certificate". RubyRuntime loads this PEM into
# that shared default store at boot. curl rotates cacert.pem as CAs change; the
# SHA256 pin keeps builds reproducible and forces a conscious refresh (re-fetch
# the file, update the pin) when CAs roll. SHA256 cross-checked against the
# cacert.pem.sha256 curl publishes alongside the file.
CACERT_PEM_URL = "https://curl.se/ca/cacert.pem"
CACERT_PEM_PATH = File.join(SRC_DIR, "cacert.pem")
CACERT_SHA256 = "f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9"

IOS_DEPLOYMENT_TARGET = "18.0" # matches IPHONEOS_DEPLOYMENT_TARGET in the project

# Functions the iOS SDK declares but doesn't let an app call. Autoconf finds them and Ruby then emits calls that fail App Store review or crash. From the xord/cruby recipe.
IOS_AC_OVERRIDES = {
  "ac_cv_func_backtrace" => "no",
  "ac_cv_func_system" => "no",
  "ac_cv_func_syscall" => "no",
  "ac_cv_func___syscall" => "no",
  "ac_cv_func_getentropy" => "no",
  "ac_cv_func_dup3" => "no",
  "ac_cv_func_pipe2" => "no",
}.freeze

# One row per SDK/arch this project builds for. lib_subdir/include_subdir are exactly Xcode's PLATFORM_NAME values, so Config/Shared.xcconfig and the "Check CRuby is built" build phase can key off $(PLATFORM_NAME) instead of enumerating SDKs. The shape of this table -- not just the macOS row -- was deliberate from slice 1: the iphoneos/iphonesimulator rows below add their own flag set (a --host + triple, --without-fiddle, the syscall/backtrace autoconf overrides) without restructuring the build functions.
TARGETS = {
  "macosx-arm64" => {
    enabled: true,
    sdk: "macosx",
    arch: "arm64",
    lib_subdir: "macosx",
    include_subdir: "macosx",
    deployment_target_env: "MACOSX_DEPLOYMENT_TARGET",
    deployment_target: "15.0",
    host: nil, # native build: the host toolchain already targets macOS arm64
    triple: nil,
  },
  "iphonesimulator-arm64" => {
    enabled: true,
    sdk: "iphonesimulator",
    arch: "arm64",
    lib_subdir: "iphonesimulator",
    include_subdir: "iphonesimulator",
    deployment_target_env: "IPHONEOS_DEPLOYMENT_TARGET",
    deployment_target: IOS_DEPLOYMENT_TARGET,
    host: "aarch64-apple-darwin",
    triple: "arm64-apple-ios18.0-simulator",
  },
  "iphoneos-arm64" => {
    enabled: true,
    sdk: "iphoneos",
    arch: "arm64",
    lib_subdir: "iphoneos",
    include_subdir: "iphoneos",
    deployment_target_env: "IPHONEOS_DEPLOYMENT_TARGET",
    deployment_target: IOS_DEPLOYMENT_TARGET,
    host: "aarch64-apple-darwin",
    triple: "arm64-apple-ios18.0",
  },
}.freeze

# Top-level names under lib/ruby/3.4.0 that don't ship in Vendor/CRuby/stdlib/.
# rdoc/bundler/rubygems/prism -- not needed for plain Kernel#require against
# $LOAD_PATH (rubycuts_init boots with --disable-gems); irb/reline/readline --
# no TTY in an app sandbox; did_you_mean/error_highlight/syntax_suggest --
# REPL-error-message niceties, not needed for running scripts; mkmf.rb -- a
# C-extension build tool, meaningless without a compiler on-device; un.rb --
# a command-line coreutils shim, not a library; ruby_vm -- RubyVM::*
# introspection helpers this app has no use for. yaml/yaml.rb ARE shipped:
# psych is now built (libyaml merged in), so `require 'yaml'` resolves.
EXCLUDED_STDLIB_ENTRIES = %w[
  bundler
  bundler.rb
  did_you_mean
  did_you_mean.rb
  error_highlight
  error_highlight.rb
  irb
  irb.rb
  mkmf.rb
  prism
  prism.rb
  rdoc
  rdoc.rb
  readline.rb
  reline
  reline.rb
  rubygems
  rubygems.rb
  ruby_vm
  syntax_suggest
  syntax_suggest.rb
  un.rb
].freeze

# Bundled gems (installed under lib/ruby/gems/#{RUBY_ABI_VERSION}/gems/, not
# lib/ruby/#{RUBY_ABI_VERSION}/) flattened into Vendor/CRuby/stdlib/ alongside
# the default-gem stdlib above, so a plain `require "csv"` finds them on
# $LOAD_PATH. Both are pure Ruby -- json/fileutils/net/http are already
# "default gems" and ship as part of lib/ruby/#{RUBY_ABI_VERSION}/ itself.
INCLUDED_BUNDLED_GEMS = %w[csv base64].freeze

def sh!(*cmd, chdir:, env: {})
  puts "+ #{cmd.join(" ")}"
  system(env, *cmd, chdir: chdir, exception: true)
end

def capture!(*cmd)
  out, status = Open3.capture2(*cmd)
  raise "#{cmd.join(" ")} failed" unless status.success?
  out
end

def check_host_ruby!
  return if RUBY_VERSION.start_with?("#{RUBY_SERIES}.")
  abort "error: host `ruby` is #{RUBY_VERSION}, need a #{RUBY_SERIES}.x " \
    "(run `mise install` first -- see mise.toml)"
end

def check_sdk!(sdk)
  path = capture!("xcrun", "--sdk", sdk, "--show-sdk-path").strip
  path
rescue StandardError
  abort "error: `xcrun --sdk #{sdk} --show-sdk-path` failed -- is Xcode installed and selected?"
end

def download_and_verify!
  download_and_verify_tarball!(TARBALL_URL, TARBALL_PATH, RUBY_VERSION_SHA256, "ruby-#{RUBY_VERSION_PIN}.tar.gz")
  download_and_verify_tarball!(OPENSSL_TARBALL_URL, OPENSSL_TARBALL_PATH, OPENSSL_SHA256, "openssl-#{OPENSSL_VERSION_PIN}.tar.gz")
  download_and_verify_tarball!(LIBYAML_TARBALL_URL, LIBYAML_TARBALL_PATH, LIBYAML_SHA256, "yaml-#{LIBYAML_VERSION_PIN}.tar.gz")
  download_and_verify_tarball!(
    SQLITE_TARBALL_URL, SQLITE_TARBALL_PATH, SQLITE_TARBALL_SHA256, "sqlite-autoconf-3530200.tar.gz"
  )
  download_and_verify_tarball!(
    SQLITE3_GEM_URL, SQLITE3_GEM_PATH, SQLITE3_GEM_SHA256, "sqlite3-#{SQLITE3_GEM_VERSION_PIN}.gem"
  )
  download_and_verify_tarball!(CACERT_PEM_URL, CACERT_PEM_PATH, CACERT_SHA256, "cacert.pem")
end

def download_and_verify_tarball!(url, path, sha256, label)
  FileUtils.mkdir_p(SRC_DIR)
  if File.exist?(path) && Digest::SHA256.file(path).hexdigest == sha256
    puts "== #{label} already downloaded and verified"
    return
  end

  puts "== downloading #{label}"
  URI.parse(url).open { |remote| File.binwrite(path, remote.read) }

  actual = Digest::SHA256.file(path).hexdigest
  return if actual == sha256

  File.delete(path)
  abort "error: sha256 mismatch for #{label}\n  expected: #{sha256}\n  actual:   #{actual}"
end

def extract!
  extract_tarball!(TARBALL_PATH, SOURCE_DIR, "ruby-#{RUBY_VERSION_PIN}", "configure")
  extract_tarball!(OPENSSL_TARBALL_PATH, OPENSSL_SOURCE_DIR, "openssl-#{OPENSSL_VERSION_PIN}", "Configure")
  extract_tarball!(LIBYAML_TARBALL_PATH, LIBYAML_SOURCE_DIR, "yaml-#{LIBYAML_VERSION_PIN}", "configure")
  extract_tarball!(SQLITE_TARBALL_PATH, SQLITE_SOURCE_DIR, "sqlite-autoconf-3530200", "sqlite3.c")
  extract_sqlite3_gem!
end

def extract_tarball!(tarball, dest_dir, label, marker)
  if File.exist?(File.join(dest_dir, marker))
    puts "== #{label} already extracted"
    return
  end

  puts "== extracting #{label}"
  sh!("tar", "xzf", tarball, "-C", SRC_DIR, chdir: ROOT)
end

# A `.gem` isn't a `.tar.gz` -- it's a plain, uncompressed tar (see
# GemArchive.swift's own hand-rolled reader) containing metadata.gz,
# data.tar.gz, and checksums.yaml.gz as flat members with no enclosing
# directory, so extract_tarball!'s "gzip into SRC_DIR, expect a
# same-named top-level dir" shape doesn't fit. Two untars instead: the
# outer .gem into a scratch dir, then its data.tar.gz payload -- the part
# that actually holds ext/ and lib/ -- into SQLITE3_GEM_SOURCE_DIR.
# Idempotent, matching extract_tarball!'s marker-file check.
def extract_sqlite3_gem!
  if File.exist?(File.join(SQLITE3_GEM_SOURCE_DIR, "ext", "sqlite3", "extconf.rb"))
    puts "== sqlite3-#{SQLITE3_GEM_VERSION_PIN}.gem already extracted"
    return
  end

  puts "== extracting sqlite3-#{SQLITE3_GEM_VERSION_PIN}.gem"
  outer_dir = File.join(SRC_DIR, "sqlite3-gem-outer")
  FileUtils.rm_rf(outer_dir)
  FileUtils.mkdir_p(outer_dir)
  sh!("tar", "xf", SQLITE3_GEM_PATH, "-C", outer_dir, chdir: ROOT)

  data_tarball = File.join(outer_dir, "data.tar.gz")
  abort "error: data.tar.gz not found inside #{SQLITE3_GEM_PATH}" unless File.exist?(data_tarball)

  FileUtils.rm_rf(SQLITE3_GEM_SOURCE_DIR)
  FileUtils.mkdir_p(SQLITE3_GEM_SOURCE_DIR)
  sh!("tar", "xzf", data_tarball, "-C", SQLITE3_GEM_SOURCE_DIR, chdir: ROOT)
end

def install_dir_for(key) = File.join(BUILD_DIR, key, "install")

def build_dir_for(key) = File.join(BUILD_DIR, key, "build")

def stub_include_dir_for(key) = File.join(BUILD_DIR, key, "stub-include")

# Per-target install prefixes for the third-party static libs. Built before
# configure_and_make! so Ruby's configure can point at them with
# --with-openssl-dir / --with-libyaml-dir, and merged into libruby-static.a
# afterward.
def openssl_install_dir_for(key) = File.join(BUILD_DIR, key, "openssl-install")

def libyaml_install_dir_for(key) = File.join(BUILD_DIR, key, "libyaml-install")

def sqlite_install_dir_for(key) = File.join(BUILD_DIR, key, "sqlite-install")

def find_static_lib(install_dir)
  Dir.glob(File.join(install_dir, "lib", "lib*-static.a")).first
end

# vm_dump.c's crash handler calls system() unconditionally for the
# RUBY_ON_BUG debug hook -- unlike everything else CRuby gates behind a
# HAVE_* check (HAVE_BACKTRACE guards the near-identical helper one
# function above, in the same file), this one isn't. It fails to compile
# wherever system() is unavailable, i.e. every iOS target, given the
# ac_cv_func_system=no override above. Not part of the xord/cruby recipe --
# found while cross-compiling -- so it's patched here instead of folded
# into IOS_AC_OVERRIDES, which only ever feeds configure, not the source.
# Guarding it with #ifdef HAVE_SYSTEM changes nothing on macOS, where
# HAVE_SYSTEM is defined.
def patch_vm_dump_system_guard!
  path = File.join(SOURCE_DIR, "vm_dump.c")
  contents = File.read(path)
  return if contents.include?("#ifdef HAVE_SYSTEM")

  unguarded = <<~C.chomp
    \x20\x20\x20\x20const char *cmd = getenv("RUBY_ON_BUG");
        if (cmd) {
            char buf[0x100];
            snprintf(buf, sizeof(buf), "%s %"PRI_PIDT_PREFIX"d", cmd, getpid());
            int r = system(buf);
            if (r == -1) {
                snprintf(buf, sizeof(buf), "Launching RUBY_ON_BUG command failed.");
            }
        }
  C
  guarded = "#ifdef HAVE_SYSTEM\n#{unguarded}\n#endif"

  unless contents.include?(unguarded)
    abort "error: vm_dump.c no longer matches the expected RUBY_ON_BUG snippet -- " \
      "update patch_vm_dump_system_guard! in scripts/build-cruby.rb"
  end
  File.write(path, contents.sub(unguarded, guarded))
end

# Bundled runtime gems with a native C extension that RubyCuts has no use
# for (Vendor/CRuby only ever takes the static lib and headers -- an
# installed gems tree never leaves .build-cruby/). On iOS they fail to
# link outright: their .bundle links the same way every Ruby C extension
# does, trusting the process that dlopen()s it to resolve core VM symbols
# (rb_eArgError and friends) at load time. On macOS that trust is spelled
# `-undefined dynamic_lookup`; Apple's iOS linker refuses the flag for any
# binary ("checking whether -Wl,-undefined,dynamic_lookup is accepted as
# LDFLAGS... no" in config.log), so every one of these bundles fails at
# link with a page of undefined symbols. Stripped from gems/bundled_gems
# before extraction, for every target (not just iOS), since none of them
# are needed anywhere. `bigdecimal`, the other C-ext bundled gem, is
# already excluded via --without-bigdecimal above, for a different
# reason (it's also a core ext/ extension) -- it doesn't need to be here.
EXCLUDED_BUNDLED_GEMS = %w[debug racc nkf rbs syslog].freeze

def patch_bundled_gems!
  path = File.join(SOURCE_DIR, "gems", "bundled_gems")
  lines = File.readlines(path)
  kept = lines.reject { |line| EXCLUDED_BUNDLED_GEMS.any? { |gem| line.start_with?("#{gem} ") } }
  File.write(path, kept.join) if kept.size != lines.size

  # extract-gems only skips a gem it finds already unpacked under
  # .bundle/gems -- shared across every target's out-of-tree build, since
  # it lives in SOURCE_DIR, not build_dir_for(key). A build that failed on
  # one of these before this exclusion existed leaves it unpacked (and
  # possibly half-built under .bundle/extensions), so removing it from
  # bundled_gems alone doesn't stop a subsequent make from finding it on
  # disk and retrying. Sweep both dirs so it doesn't.
  EXCLUDED_BUNDLED_GEMS.each do |gem|
    FileUtils.rm_rf(Dir.glob(File.join(SOURCE_DIR, ".bundle", "gems", "#{gem}-*")))
    FileUtils.rm_rf(Dir.glob(File.join(SOURCE_DIR, ".bundle", "extensions", "*", "*", "#{gem}-*")))
  end
end

# ext/psych/extconf.rb's default branch calls `pkg_config('yaml-0.1')`
# unconditionally before dir_config('libyaml')/find_header/find_library. On a
# build machine with pkg-config + a host Homebrew libyaml installed, that
# pkg_config call picks up the host (x86_64 or arm64-macOS) libyaml and
# contaminates the iOS cross-compile with the wrong arch. Neutralize it so
# the dir_config('libyaml') + --with-libyaml-dir path is the only one taken.
# (Matches the xord/cruby recipe.) Idempotent, once per checkout.
def patch_psych_extconf!
  path = File.join(SOURCE_DIR, "ext", "psych", "extconf.rb")
  contents = File.read(path)
  return if contents.include?("pkg_config('yaml-0.1') # neutralized")

  target = "  pkg_config('yaml-0.1')\n"
  replacement = "  # pkg_config('yaml-0.1') # neutralized by patch_psych_extconf! (scripts/build-cruby.rb); --with-libyaml-dir drives dir_config('libyaml') below, so a host Homebrew libyaml can't contaminate a cross-compile\n"
  unless contents.include?(target)
    abort "error: ext/psych/extconf.rb no longer has the expected pkg_config('yaml-0.1') line -- " \
      "update patch_psych_extconf! in scripts/build-cruby.rb"
  end
  File.write(path, contents.sub(target, replacement))
end

# The sqlite3 gem's ext/sqlite3/*.c and *.h files (its C binding glue --
# Init_sqlite3_native and friends, not the SQLite library itself), copied
# verbatim into CRuby's own ext/ tree so --with-static-linked-ext compiles
# and registers them as a statically-linked extension, the same mechanism
# that already builds stringio/json/socket/etc. Called from main alongside
# patch_psych_extconf!, i.e. before any target's configure_and_make! runs --
# CRuby's configure enumerates ext/*/extconf.rb at configure time, so the
# files have to exist before that, not per-target.
EXPECTED_SQLITE3_EXT_SOURCES = %w[
  aggregator.c aggregator.h backup.c backup.h database.c database.h
  exception.c exception.h sqlite3.c sqlite3_ruby.h statement.c statement.h
  timespec.h
].freeze

def install_sqlite3_ext_sources!
  dest_dir = File.join(SOURCE_DIR, "ext", "sqlite3")
  if File.exist?(File.join(dest_dir, "sqlite3.c"))
    puts "== ext/sqlite3 sources already installed"
    return
  end

  gem_ext_dir = File.join(SQLITE3_GEM_SOURCE_DIR, "ext", "sqlite3")
  sources = Dir.children(gem_ext_dir).select { |name| name.end_with?(".c", ".h") }.sort
  unless sources == EXPECTED_SQLITE3_EXT_SOURCES.sort
    abort "error: sqlite3 gem's ext/sqlite3/ no longer matches the expected .c/.h file " \
      "list (found #{sources.inspect}, expected #{EXPECTED_SQLITE3_EXT_SOURCES.sort.inspect}) " \
      "-- update install_sqlite3_ext_sources! and EXPECTED_SQLITE3_EXT_SOURCES in " \
      "scripts/build-cruby.rb"
  end

  FileUtils.mkdir_p(dest_dir)
  sources.each { |name| FileUtils.cp(File.join(gem_ext_dir, name), File.join(dest_dir, name)) }

  # A trimmed copy of the gem's own ext/sqlite3/extconf.rb: the
  # mini_portile2/pkg-config machinery that downloads and cross-compiles
  # SQLite itself is gone (build_sqlite! already did that, into
  # sqlite_install_dir_for(key), reached below via --with-sqlite3-dir --
  # see configure_and_make!), and the sqlite3_enable_load_extension /
  # sqlite3_load_extension have_func probes are dropped on purpose -- see
  # the SQLITE_OMIT_LOAD_EXTENSION comment in build_sqlite! -- so
  # database.c's `#ifdef HAVE_SQLITE3_*_LOAD_EXTENSION` guards never see
  # those macros defined and compile the load_extension/enable_load_extension
  # Ruby methods out entirely. `create_makefile("sqlite3/sqlite3_native")`
  # matches lib/sqlite3.rb's fallback `require "sqlite3/sqlite3_native"`
  # exactly, so the gem's own Ruby needs no patching.
  File.write(File.join(dest_dir, "extconf.rb"), <<~RUBY)
    # Generated by install_sqlite3_ext_sources! in scripts/build-cruby.rb.
    require "mkmf"

    dir_config("sqlite3")
    append_cppflags("-DUSING_PACKAGED_LIBRARIES")
    append_cflags("-fvisibility=hidden")

    abort("could not find sqlite3.h") unless find_header("sqlite3.h")
    unless find_library("sqlite3", "sqlite3_libversion_number", "sqlite3.h")
      abort("could not find sqlite3")
    end

    %w[
      rb_enc_interned_str_cstr rb_proc_arity rb_integer_pack
      sqlite3_initialize sqlite3_backup_init sqlite3_column_database_name
      sqlite3_open_v2 sqlite3_prepare_v2
    ].each { |func| have_func(func) }
    have_func("sqlite3_db_name", "sqlite3.h")
    have_func("sqlite3_error_offset", "sqlite3.h")
    have_type("sqlite3_int64", "sqlite3.h")
    have_type("sqlite3_uint64", "sqlite3.h")

    # CRuby's own --with-static-linked-ext build makes every HAVE_* macro
    # visible to a source file only indirectly, through a generated
    # extconf.h transitively #include'd by ruby.h/ruby/config.h -- fine for
    # every file here except backup.c, whose very first line is
    # `#ifdef HAVE_SQLITE3_BACKUP_INIT`, checked before that file includes
    # anything at all. Under a normal standalone gem build $defs' `-DHAVE_*`
    # flags land directly on the compiler command line (visible from a
    # file's first token), so this asymmetry never shows up there -- it's
    # specific to being folded into CRuby's own extconf.h convention.
    # Re-appending $defs onto $CFLAGS puts the same `-DHAVE_*` flags
    # directly on the compile line too, so backup.c's guard sees them
    # regardless of include order. Confirmed necessary by a real cross build
    # (an iphonesimulator-arm64 link failed on `_init_sqlite3_backup`
    # undefined -- macOS's `-Wl,-undefined,dynamic_lookup` masked the same
    # gap there, so trust this fix's necessity, not the lack of a macOS
    # error).
    append_cflags($defs.join(" "))

    create_makefile("sqlite3/sqlite3_native")
  RUBY
  puts "== ext/sqlite3 sources + extconf.rb installed under #{dest_dir}"
end

# The iOS SDKs (device and simulator) don't ship sys/vnode.h. dir.c includes
# it unconditionally under #ifdef __APPLE__ (dir.c:100) with no autoconf
# guard around it, so the build hard-fails without a stub. It can't be an
# empty header: dir.c:2252-2254 compares getattrlist() results against
# VREG/VDIR/VLNK, and dir.c:211-212/3784 compare against VT_HFS/VT_CIFS, so
# this redeclares both enum vtype and enum vtagtype with the same member
# ordering as the macOS SDK's header -- the ordering is load-bearing.
# fsobj_tag_t itself doesn't need redeclaring; it's a plain u_int32_t typedef
# in sys/attr.h, which the iOS SDKs do ship.
def write_vnode_stub!(key)
  dir = File.join(stub_include_dir_for(key), "sys")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "vnode.h"), <<~C)
    /* Stub for the iOS SDKs, which don't ship this header -- see dir.c:100
     * (unconditional include), dir.c:2252-2254 (VREG/VDIR/VLNK usage), and
     * dir.c:211-212/3784 (VT_HFS/VT_CIFS usage).
     * scripts/build-cruby.rb's write_vnode_stub! generates this file. */
    #ifndef RUBYCUTS_STUB_SYS_VNODE_H
    #define RUBYCUTS_STUB_SYS_VNODE_H

    enum vtype { VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD, VSTR, VCPLX };

    enum vtagtype {
      VT_NON,
      VT_UFS,
      VT_NFS, VT_MFS, VT_MSDOSFS, VT_LFS,
      VT_LOFS, VT_FDESC, VT_PORTAL, VT_NULL, VT_UMAP,
      VT_KERNFS, VT_PROCFS, VT_AFS, VT_ISOFS, VT_MOCKFS,
      VT_HFS, VT_ZFS, VT_DEVFS, VT_WEBDAV, VT_UDF,
      VT_AFP, VT_CDDA, VT_CIFS, VT_OTHER, VT_APFS,
      VT_LOCKERFS, VT_BINDFS,
    };

    #endif
  C
end

# SQLite (the amalgamation, not the SDK's own libsqlite3 -- see the
# SQLITE_VERSION_PIN comment for why). No `configure` at all: unlike
# libyaml/OpenSSL, SQLite 3.49+'s autosetup-based configure isn't worth
# cross-compiling against for what's ultimately a single translation unit
# (sqlite3.c). Compiling it directly with the same feature-flag set the
# gem's own packaged (mini_portile2) build uses -- minus load-extension
# support, which is dropped on purpose (see the SQLITE_OMIT_LOAD_EXTENSION
# flag below and install_sqlite3_ext_sources!'s comment) -- is simpler and
# just as correct. Archived into an install prefix shaped exactly like
# build_libyaml!'s (lib/libsqlite3.a + include/*.h), so ext/sqlite3's
# dir_config("sqlite3") finds it via --with-sqlite3-dir the same way
# psych's dir_config("libyaml") finds libyaml_install_dir_for. Called first
# in the per-target loop, purely by convention (no ordering dependency on
# libyaml/openssl). Idempotent (skips if libsqlite3.a already exists) and
# out-of-tree, mirroring build_libyaml!.
def build_sqlite!(key, target)
  install_dir = sqlite_install_dir_for(key)
  if File.exist?(File.join(install_dir, "lib", "libsqlite3.a"))
    puts "== #{key} sqlite already built"
    return
  end

  sdk_path = check_sdk!(target[:sdk])
  build_dir = File.join(BUILD_DIR, key, "sqlite-build")
  FileUtils.rm_rf(build_dir)
  FileUtils.mkdir_p(build_dir)
  FileUtils.mkdir_p(File.join(install_dir, "lib"))
  FileUtils.mkdir_p(File.join(install_dir, "include"))

  cc = ["xcrun", "--sdk", target[:sdk], "cc", "-arch", target[:arch]]
  cflags = %w[
    -Os -fPIC -fvisibility=hidden
    -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA
    -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_DBPAGE_VTAB
    -DSQLITE_USE_URI=1 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
    -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1
  ]
  cflags += ["-target", target[:triple], "-isysroot", sdk_path] if target[:triple]

  env = { target[:deployment_target_env] => target[:deployment_target] }

  puts "== compiling #{key} sqlite3.c"
  sh!(
    *cc, *cflags, "-c", File.join(SQLITE_SOURCE_DIR, "sqlite3.c"), "-o", "sqlite3.o",
    chdir: build_dir, env: env
  )

  puts "== archiving #{key} libsqlite3.a"
  sh!(
    "libtool", "-static", "-o", File.join(install_dir, "lib", "libsqlite3.a"), "sqlite3.o",
    chdir: build_dir
  )

  FileUtils.cp(File.join(SQLITE_SOURCE_DIR, "sqlite3.h"), File.join(install_dir, "include"))
  FileUtils.cp(File.join(SQLITE_SOURCE_DIR, "sqlite3ext.h"), File.join(install_dir, "include"))
end

# libyaml (psych's C backend). Autoconf, so simpler than OpenSSL -- built
# first to de-risk. Idempotent: skips if libyaml.a is already installed.
# Native on macOS; cross-compiled for iOS by pointing CC at the SDK via xcrun
# and carrying -target <triple> -isysroot <sdk> on CFLAGS/LDFLAGS, the same
# triple/sysroot the Ruby cross-compile uses. Out-of-tree (its own build dir)
# so the three targets never share configure state.
def build_libyaml!(key, target)
  install_dir = libyaml_install_dir_for(key)
  if File.exist?(File.join(install_dir, "lib", "libyaml.a"))
    puts "== #{key} libyaml already built"
    return
  end

  sdk_path = check_sdk!(target[:sdk])
  build_dir = File.join(BUILD_DIR, key, "libyaml-build")
  FileUtils.rm_rf(build_dir)
  FileUtils.mkdir_p(build_dir)

  env = { target[:deployment_target_env] => target[:deployment_target] }
  configure_args = ["--prefix=#{install_dir}", "--enable-static", "--disable-shared"]

  if target[:host]
    configure_args << "--host=#{target[:host]}"
    env["CC"] = "xcrun --sdk #{target[:sdk]} cc -arch #{target[:arch]}"
    env["CFLAGS"] = "-target #{target[:triple]} -isysroot #{sdk_path}"
    env["LDFLAGS"] = "-target #{target[:triple]} -isysroot #{sdk_path}"
    env["SDKROOT"] = sdk_path
  end

  puts "== configuring #{key} libyaml"
  sh!(File.join(LIBYAML_SOURCE_DIR, "configure"), *configure_args, chdir: build_dir, env: env)
  jobs = capture!("sysctl", "-n", "hw.ncpu").strip
  sh!("make", "-j#{jobs}", chdir: build_dir, env: env)
  sh!("make", "install", chdir: build_dir, env: env)
end

# OpenSSL (TLS for net/http). Uses OpenSSL's own Perl Configure with its
# built-in Apple targets -- darwin64-arm64-cc (macOS), ios64-xcrun (device),
# iossimulator-xcrun (simulator) -- which drive clang via `xcrun -sdk <sdk>
# cc` and auto-select the SDK. Those targets don't pin a deployment target,
# so CFLAGS carries -target <triple> (Configure:770 appends the CFLAGS env to
# the target's flags), pinning arch + min iOS version; the native macOS build
# needs no -target. Built out-of-tree (each target its own build dir) so
# reconfiguring for a different SDK never leaves the previous target's objects
# in the source tree. Idempotent. `no-apps` skips the openssl CLI (and
# cascades to disable `tests`); `install_sw` installs libssl.a/libcrypto.a +
# headers, skipping docs/engines.
def build_openssl!(key, target)
  install_dir = openssl_install_dir_for(key)
  if File.exist?(File.join(install_dir, "lib", "libssl.a")) &&
     File.exist?(File.join(install_dir, "lib", "libcrypto.a"))
    puts "== #{key} openssl already built"
    return
  end

  check_sdk!(target[:sdk])
  ossl_target =
    case target[:sdk]
    when "macosx" then "darwin64-arm64-cc"
    when "iphoneos" then "ios64-xcrun"
    when "iphonesimulator" then "iossimulator-xcrun"
    else abort "error: no OpenSSL Configure target mapped for sdk #{target[:sdk].inspect}"
    end

  env = { target[:deployment_target_env] => target[:deployment_target] }
  env["CFLAGS"] = "-target #{target[:triple]}" if target[:triple]

  configure_args = [ossl_target, "no-shared", "no-tests", "no-apps", "--prefix=#{install_dir}"]

  build_dir = File.join(BUILD_DIR, key, "openssl-build")
  FileUtils.rm_rf(build_dir)
  FileUtils.mkdir_p(build_dir)

  puts "== configuring #{key} openssl (#{ossl_target})"
  sh!("perl", File.join(OPENSSL_SOURCE_DIR, "Configure"), *configure_args, chdir: build_dir, env: env)
  jobs = capture!("sysctl", "-n", "hw.ncpu").strip
  puts "== building #{key} openssl"
  sh!("make", "-j#{jobs}", chdir: build_dir, env: env)
  sh!("make", "install_sw", chdir: build_dir, env: env)
end

def configure_and_make!(key, target)
  install_dir = install_dir_for(key)
  if find_static_lib(install_dir)
    puts "== #{key} already built"
    return
  end

  sdk_path = check_sdk!(target[:sdk])
  build_dir = build_dir_for(key)
  FileUtils.rm_rf(build_dir)
  FileUtils.mkdir_p(build_dir)

  configure_args = [
    "--prefix=#{install_dir}",
    "--disable-shared",
    "--disable-dln",
    "--disable-install-doc",
    "--with-static-linked-ext",
    "--without-bigdecimal",
    "--without-readline",
    "--without-fiddle", # App Store review flags apps that can load arbitrary native code via dlopen/FFI; dropped for every target, not just iOS, so macOS and iOS stay built from the same flag set.
    "--with-out-ext=bigdecimal*,readline*,fiddle*",
    # Point the openssl/psych extconfs at the per-target third-party installs
    # built above. Ruby's configure forwards every --with-* arg (stored in
    # ac_configure_args) to each ext's extconf, where mkmf's dir_config reads
    # them -- so ext/openssl/extconf.rb's dir_config("openssl") and
    # ext/psych/extconf.rb's dir_config("libyaml") find these builds instead of
    # probing the host.
    "--with-openssl-dir=#{openssl_install_dir_for(key)}",
    "--with-libyaml-dir=#{libyaml_install_dir_for(key)}",
    "--with-sqlite3-dir=#{sqlite_install_dir_for(key)}",
  ]
  configure_args << "--host=#{target[:host]}" if target[:host]
  # Cross-compiles need a base Ruby to run CRuby's own generator scripts during the build; check_host_ruby! already guarantees the host `ruby`'s minor version matches.
  configure_args << "--with-baseruby=#{RbConfig.ruby}" if target[:host]

  cflags = "-pipe -Os -fvisibility=hidden"
  # The openssl/psych/sqlite3 exts propagate -lssl/-lcrypto/-lyaml/-lsqlite3
  # to the ruby executable's link: under --with-static-linked-ext the exts
  # link into the ruby binary (not into lib*-static.a -- that move is
  # merge_static_extensions!'s post-make job), so `make` has to find those
  # libs on its link line. The per-target third-party install dirs go on
  # the link search path for that. (The shipped libruby-static.a gets these
  # libs folded in by merge_static_extensions! instead; this LDFLAGS only
  # lets `make` link its intermediate ruby binary, which never ships.)
  # libcrypto.a's one external ref, _CCRandomGenerateBytes, resolves from
  # libSystem on both macOS and iOS, so no -framework Security is needed.
  third_party_ldflags =
    "-L#{openssl_install_dir_for(key)}/lib -L#{libyaml_install_dir_for(key)}/lib " \
    "-L#{sqlite_install_dir_for(key)}/lib"
  env = {
    "CFLAGS" => cflags,
    target[:deployment_target_env] => target[:deployment_target],
    "LDFLAGS" => third_party_ldflags,
  }
  # Cross-compiles (slice 2) can't rely on the toolchain's default SDK and must force it explicitly; a native build picks up Xcode's default.
  env["SDKROOT"] = sdk_path if target[:host]

  if target[:triple]
    write_vnode_stub!(key)
    env["CFLAGS"] = "#{cflags} -target #{target[:triple]} -isysroot #{sdk_path} -I#{stub_include_dir_for(key)}"
    # configure's own link probes need the target/sysroot too, not just the compile step; the third-party -L paths stay on the link line.
    env["LDFLAGS"] = "-target #{target[:triple]} -isysroot #{sdk_path} #{third_party_ldflags}"
    env.merge!(IOS_AC_OVERRIDES)
  end

  puts "== configuring #{key}"
  sh!(File.join(SOURCE_DIR, "configure"), *configure_args, chdir: build_dir, env: env)

  puts "== building #{key} (this takes 10-20 minutes)"
  jobs = capture!("sysctl", "-n", "hw.ncpu").strip
  sh!("make", "-j#{jobs}", chdir: build_dir, env: env)
  sh!("make", "install", chdir: build_dir, env: env)
end

# --with-static-linked-ext links every statically-linked C extension
# (stringio, json/ext, socket, date_core, strscan, ...) into its own
# per-extension archive (ext/<name>/<name>.a) and generates ext/extinit.c
# to register them all -- but the generated Makefile's object list for
# lib*-static.a ($(LIBRUBY_A_OBJS), i.e. $(OBJS)) never includes them; only
# the final `ruby` executable's own link recipe does (traced in the actual
# generated Makefile/exts.mk, not assumed from the configure flags). Left
# alone, lib*-static.a ships dmyext.o's empty Init_ext() stub instead of
# the real one, so `require` of any statically-linked extension fails with
# "cannot load such file" -- confirmed by probing the built archive with
# `nm`. Same story for enc/encinit.o vs the dmyenc.o stub and the non-ASCII
# encoding tables in enc/libenc.a + enc/libtrans.a (without it, e.g.
# Encoding.find("Shift_JIS") raises).
#
# Fixed here by rebuilding lib*-static.a after `make install`: drop the two
# stub objects and merge in the real ones with `libtool -static`, which --
# unlike plain `ar` -- flattens nested .a members into the output archive
# instead of embedding them as archive-in-archive members `ar` can't see
# into.
#
# The same step folds in the third-party static libraries (libssl.a,
# libcrypto.a from build_openssl!, libyaml.a from build_libyaml!) by appending
# them to the same libtool filelist. Once flattened into lib*-static.a, the
# existing `-Wl,-force_load,...libruby-static.a` in Config/Shared.xcconfig
# pulls them into the app link with no new link flag. Contingency (only if
# `libtool -static` errors on duplicate member names -- libyaml's api.o /
# reader.o are the generic-name collision candidates): switch to the
# explode-rename-rearchive method -- extract every archive into a temp dir,
# rename colliding .o's with a numeric prefix, exclude dmyext.o/dmyenc.o,
# then `ar -crs` everything plus extinit.o/encinit.o into the final archive.
# Not used today because the filelist path builds clean.
def merge_static_extensions!(key)
  install_dir = install_dir_for(key)
  build_dir = build_dir_for(key)
  static_lib = find_static_lib(install_dir)
  abort "error: no lib*-static.a found under #{install_dir}/lib -- run configure_and_make! first" unless static_lib

  members = capture!("ar", "t", static_lib).lines(chomp: true)
  unless members.include?("dmyext.o")
    puts "== #{key} static extensions already merged"
    return
  end

  stripped = "#{static_lib}.stripped"
  FileUtils.cp(static_lib, stripped)
  sh!("ar", "d", stripped, "dmyext.o", "dmyenc.o", chdir: build_dir)

  ext_archives = Dir.glob(File.join(build_dir, "ext", "**", "*.a")).sort
  third_party_archives = [
    File.join(openssl_install_dir_for(key), "lib", "libssl.a"),
    File.join(openssl_install_dir_for(key), "lib", "libcrypto.a"),
    File.join(libyaml_install_dir_for(key), "lib", "libyaml.a"),
    File.join(sqlite_install_dir_for(key), "lib", "libsqlite3.a"),
  ]
  third_party_archives.each do |archive|
    next if File.exist?(archive)
    abort "error: #{archive} missing -- run build_openssl!/build_libyaml!/build_sqlite! before merge_static_extensions!"
  end

  filelist_entries = [stripped, File.join(build_dir, "ext", "extinit.o")] + ext_archives + [
    File.join(build_dir, "enc", "encinit.o"),
    File.join(build_dir, "enc", "libenc.a"),
    File.join(build_dir, "enc", "libtrans.a"),
  ] + third_party_archives
  filelist = "#{static_lib}.filelist"
  File.write(filelist, "#{filelist_entries.join("\n")}\n")

  puts "== merging statically-linked extensions + openssl/libyaml into #{key}'s static lib"
  merged = "#{static_lib}.merged"
  sh!("libtool", "-static", "-o", merged, "-filelist", filelist, chdir: build_dir)
  FileUtils.mv(merged, static_lib)
  FileUtils.rm_f(stripped)
  FileUtils.rm_f(filelist)
end

def install_artifacts!(key, target)
  install_dir = install_dir_for(key)
  static_lib = find_static_lib(install_dir)
  abort "error: no lib*-static.a found under #{install_dir}/lib -- " \
    "delete #{build_dir_for(key)} and re-run" unless static_lib

  lib_dest_dir = File.join(VENDOR_DIR, "lib", target[:lib_subdir])
  FileUtils.mkdir_p(lib_dest_dir)
  # Normalized to a fixed name regardless of what CRuby's --with-soname default calls it (on Darwin that default is version-suffixed), so Config/Shared.xcconfig can reference one path per SDK.
  FileUtils.cp(static_lib, File.join(lib_dest_dir, "libruby-static.a"))

  generic_include = File.join(install_dir, "include", "ruby-#{RUBY_ABI_VERSION}")
  include_dest = File.join(VENDOR_DIR, "include", target[:include_subdir])
  FileUtils.mkdir_p(include_dest)

  # Ruby installs generic headers directly under ruby-3.4.0/, plus one arch-specific subdirectory (e.g. ruby-3.4.0/arm64-darwin24/) holding just ruby/config.h. We flatten both into Vendor/CRuby/include/<platform>/ -- one complete tree per SDK, since HEADER_SEARCH_PATHS in Config/Shared.xcconfig is $(PLATFORM_NAME)-parameterized. Each tree only ever has one arch-specific config.h to overlay, so the flatten below stays a straight copy per target.
  arch_dirs = Dir.children(generic_include).map { |name| File.join(generic_include, name) }
    .select { |path| File.exist?(File.join(path, "ruby", "config.h")) }
  abort "error: no arch-specific ruby/config.h found under #{generic_include}" if arch_dirs.empty?

  (Dir.children(generic_include).map { |name| File.join(generic_include, name) } - arch_dirs).each do |entry|
    FileUtils.cp_r(entry, include_dest)
  end
  arch_dirs.each do |arch_dir|
    FileUtils.cp(File.join(arch_dir, "ruby", "config.h"), File.join(include_dest, "ruby", "config.h"))
  end
end

# The one child of lib/ruby/#{RUBY_ABI_VERSION} that isn't shared across
# targets: it holds only rbconfig.rb, which embeds this machine's absolute
# --prefix/--host build paths, so it's never copied into Vendor/CRuby/stdlib/
# (see EXCLUDED_STDLIB_ENTRIES's comment and docs/embedding-cruby.md).
# Detected by content, not by a hardcoded name (e.g. "arm64-darwin25"), so a
# future Ruby version's arch-triple naming doesn't silently ship the wrong
# thing or silently skip the check.
def stdlib_arch_subdir(stdlib_dir)
  candidates = Dir.children(stdlib_dir).select { |name| File.file?(File.join(stdlib_dir, name, "rbconfig.rb")) }
  unless candidates.size == 1
    abort "error: expected exactly one arch subdir with rbconfig.rb under #{stdlib_dir}, " \
      "found #{candidates.size}: #{candidates.inspect}"
  end
  candidates.first
end

# SHA256 over every file's relative path plus its content, under
# lib/ruby/#{RUBY_ABI_VERSION}, excluding the arch subdir (which is expected
# to differ across targets and is never bundled anyway). Used to turn "the
# stdlib is identical across all three targets" from a standing assumption
# into a build-time assertion before install_stdlib! copies from just one of
# them.
def stdlib_digest(install_dir)
  stdlib_dir = File.join(install_dir, "lib", "ruby", RUBY_ABI_VERSION)
  arch_subdir = stdlib_arch_subdir(stdlib_dir)

  digest = Digest::SHA256.new
  Dir.glob(File.join(stdlib_dir, "**", "*")).sort.each do |path|
    next if File.directory?(path)

    relative = path.delete_prefix("#{stdlib_dir}/")
    next if relative.start_with?("#{arch_subdir}/")

    digest << relative
    digest << File.binread(path)
  end
  digest.hexdigest
end

def assert_stdlib_identical!(targets)
  digests = targets.keys.to_h { |key| [key, stdlib_digest(install_dir_for(key))] }
  return if digests.values.uniq.size == 1

  abort "error: lib/ruby/#{RUBY_ABI_VERSION} differs across targets, expected byte-identical " \
    "trees -- #{digests.inspect}"
end

# Copies the deny-listed stdlib plus INCLUDED_BUNDLED_GEMS into
# Vendor/CRuby/stdlib/ -- one shared tree, not one per platform, since
# assert_stdlib_identical! already proved the three installs match.
def install_stdlib!(install_dir)
  FileUtils.rm_rf(STDLIB_DEST)
  FileUtils.mkdir_p(STDLIB_DEST)

  stdlib_dir = File.join(install_dir, "lib", "ruby", RUBY_ABI_VERSION)
  arch_subdir = stdlib_arch_subdir(stdlib_dir)

  Dir.children(stdlib_dir).each do |entry|
    next if entry == arch_subdir
    next if EXCLUDED_STDLIB_ENTRIES.include?(entry)

    FileUtils.cp_r(File.join(stdlib_dir, entry), STDLIB_DEST)
  end

  gems_dir = File.join(install_dir, "lib", "ruby", "gems", RUBY_ABI_VERSION, "gems")
  INCLUDED_BUNDLED_GEMS.each do |gem_name|
    matches = Dir.glob(File.join(gems_dir, "#{gem_name}-*"))
    unless matches.size == 1
      abort "error: expected exactly one #{gem_name}-* dir under #{gems_dir}, " \
        "found #{matches.size}: #{matches.inspect}"
    end

    gem_lib = File.join(matches.first, "lib")
    Dir.children(gem_lib).each do |child|
      dest = File.join(STDLIB_DEST, child)
      abort "error: #{gem_name} gem's lib/#{child} collides with an existing stdlib entry at #{dest}" if File.exist?(dest)

      FileUtils.cp_r(File.join(gem_lib, child), STDLIB_DEST)
    end
  end

  # Should be impossible given EXCLUDED_STDLIB_ENTRIES and INCLUDED_BUNDLED_GEMS
  # are both pure-Ruby-only lists, but cheap to assert instead of trusting that.
  compiled = Dir.glob(File.join(STDLIB_DEST, "**", "*.{bundle,so,dylib}"))
  abort "error: unexpected compiled extension(s) bundled into stdlib: #{compiled.inspect}" unless compiled.empty?

  files = Dir.glob(File.join(STDLIB_DEST, "**", "*")).select { |path| File.file?(path) }
  total_bytes = files.sum { |path| File.size(path) }
  puts "== stdlib installed: #{files.size} files, #{(total_bytes / 1024.0 / 1024.0).round(1)} MB, under #{STDLIB_DEST}"
end

# Copies the sqlite3 gem's Ruby-side lib/ into Vendor/CRuby/stdlib/,
# alongside the stdlib and INCLUDED_BUNDLED_GEMS entries install_stdlib!
# already put there -- sqlite3 itself isn't in INCLUDED_BUNDLED_GEMS because
# its source lives under .build-cruby/src (SQLITE3_GEM_SOURCE_DIR, fetched
# directly from rubygems.org), not inside the CRuby install's own gems/
# directory that INCLUDED_BUNDLED_GEMS reads from.
#
# lib/sqlite3.rb's own fallback (`require "sqlite3/#{ruby_minor}/sqlite3_native"`
# rescued into `require "sqlite3/sqlite3_native"`) resolves against exactly
# the feature name install_sqlite3_ext_sources!'s generated extconf.rb
# registers via `create_makefile`, so nothing here needs to patch the gem's
# Ruby to make that resolve.
def install_sqlite3_ruby_lib!
  gem_lib = File.join(SQLITE3_GEM_SOURCE_DIR, "lib")
  %w[sqlite3.rb sqlite3].each do |entry|
    dest = File.join(STDLIB_DEST, entry)
    if File.exist?(dest)
      abort "error: sqlite3 gem's lib/#{entry} collides with an existing stdlib entry at #{dest}"
    end

    FileUtils.cp_r(File.join(gem_lib, entry), STDLIB_DEST)
  end

  # Should be impossible -- the source gem ships no compiled extension --
  # but cheap to assert instead of trusting that, matching install_stdlib!'s
  # equivalent check.
  compiled = Dir.glob(File.join(STDLIB_DEST, "sqlite3", "**", "*.{bundle,so,dylib}"))
  unless compiled.empty?
    abort "error: unexpected compiled extension(s) bundled from the sqlite3 gem: #{compiled.inspect}"
  end

  puts "== sqlite3 gem's lib/ installed under #{STDLIB_DEST}"
end

# Ships a sanitized rbconfig.rb at the stdlib root (the one $LOAD_PATH
# entry, so `require 'rbconfig'` finds it). The arch subdir that holds the
# unsanitized original is already skipped by install_stdlib! (detected by
# content via stdlib_arch_subdir), so this *adds* a clean copy at the root
# rather than touching the skipped subdir.
#
# Why a string rewrite and not just a move: the original's TOPDIR line is
# `File.dirname(__FILE__).chomp!("/lib/ruby/3.4.0/<arch>")`. Relocated to the
# stdlib root, __FILE__ no longer ends in that suffix, chomp! returns nil, so
# TOPDIR is nil and CONFIG["prefix"] falls back to `DESTDIR + "<dev path>"`.
# Relocation alone therefore ships the dev-machine install path; rewriting that
# path to a neutral token makes the fallback resolve to the token instead.
# The host/target/build/arch family is left untouched -- it carries no absolute
# paths, and host_os ("darwin25") is exactly what makes resolv's WINDOWS check
# resolve to non-Windows on every platform. The full RbConfig.expand /
# MAKEFILE_CONFIG / fire_update! machinery stays intact so the whole RbConfig
# surface remains available to any consumer (logger, fileutils, mkmf, ...).
def sanitize_rbconfig!(install_dir)
  stdlib_dir = File.join(install_dir, "lib", "ruby", RUBY_ABI_VERSION)
  arch_subdir = stdlib_arch_subdir(stdlib_dir)
  src = File.join(stdlib_dir, arch_subdir, "rbconfig.rb")
  abort "error: no rbconfig.rb found at #{src} -- run configure_and_make! first" unless File.exist?(src)

  contents = File.read(src)
  dev_prefix = install_dir_for("macosx-arm64")

  # Replace the dev-machine install prefix everywhere it appears: prefix,
  # RUBY_EXEC_PREFIX, configure_args, and any $(prefix)-derived value
  # RbConfig.expand resolves at load time.
  contents.gsub!(dev_prefix, "/usr/local")

  # Homebrew's GNU coreutils (ginstall/gmkdir) shadow the BSD tools on the
  # build machine; the app sandbox only has the BSD names, so point at those.
  contents.gsub!(%r{/opt/homebrew/bin/ginstall -c}, "install -c")
  contents.gsub!(%r{/opt/homebrew/bin/gmkdir -p}, "mkdir -p")

  # Build-time guard against an incomplete rewrite: nothing of the dev prefix
  # or a Homebrew path may remain in the shipped file.
  if contents.include?(dev_prefix) || contents.include?("/opt/homebrew")
    abort "error: sanitized rbconfig.rb still contains a dev-machine path -- " \
      "update sanitize_rbconfig! in scripts/build-cruby.rb"
  end

  File.write(File.join(STDLIB_DEST, "rbconfig.rb"), contents)
  puts "== sanitized rbconfig.rb installed under #{STDLIB_DEST}"
end

# Ships the Mozilla CA bundle (curl's cacert.pem) at the stdlib root. It bundles
# via the existing stdlib folder reference (no new Xcode resource entry) and is
# locatable at runtime as $LOAD_PATH.first/cacert.pem, which RubyRuntime loads
# into OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE at boot. Lives under stdlib/
# rather than its own resource because that's the one folder reference already
# wired into Copy Bundle Resources -- adding a sibling would mean hand-editing the
# pbxproj, and sanitize_rbconfig! already ships a non-stdlib file the same way.
def install_ca_bundle!
  abort "error: cacert.pem not downloaded -- run download_and_verify! first" unless File.exist?(CACERT_PEM_PATH)
  dest = File.join(STDLIB_DEST, "cacert.pem")
  FileUtils.cp(CACERT_PEM_PATH, dest)
  puts "== CA bundle installed: #{File.size(dest)} bytes (Mozilla/curl cacert.pem) under #{STDLIB_DEST}"
end

def main
  check_host_ruby!

  if ARGV.include?("--clean")
    puts "== --clean: removing #{BUILD_DIR} and #{VENDOR_DIR}"
    FileUtils.rm_rf(BUILD_DIR)
    FileUtils.rm_rf(VENDOR_DIR)
  end

  download_and_verify!
  extract!
  patch_vm_dump_system_guard!
  patch_bundled_gems!
  patch_psych_extconf!
  install_sqlite3_ext_sources!

  targets = TARGETS.select { |_, target| target[:enabled] }
  abort "error: no targets enabled in TARGETS" if targets.empty?

  targets.each do |key, target|
    puts "== target: #{key}"
    build_sqlite!(key, target)
    build_libyaml!(key, target)
    build_openssl!(key, target)
    configure_and_make!(key, target)
    merge_static_extensions!(key)
    install_artifacts!(key, target)
  end

  # lib/ruby/#{RUBY_ABI_VERSION} is identical across every target (confirmed
  # by assert_stdlib_identical! below, not just assumed), so it's installed
  # once from whichever target's install dir, not once per target.
  # "macosx-arm64" specifically because TARGETS guarantees it's always
  # enabled.
  assert_stdlib_identical!(targets)
  install_stdlib!(install_dir_for("macosx-arm64"))
  install_sqlite3_ruby_lib!
  sanitize_rbconfig!(install_dir_for("macosx-arm64"))
  install_ca_bundle!

  puts "== done -- static libs, headers, and stdlib installed under #{VENDOR_DIR}"
end

main if $PROGRAM_NAME == __FILE__
