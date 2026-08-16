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
# introspection helpers this app has no use for; yaml/yaml.rb -- configure
# ran with --without-psych (see docs/embedding-cruby.md), so `require 'yaml'`
# would just raise a worse-looking LoadError than leaving it out entirely.
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
  yaml
  yaml.rb
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
  FileUtils.mkdir_p(SRC_DIR)
  if File.exist?(TARBALL_PATH) && Digest::SHA256.file(TARBALL_PATH).hexdigest == RUBY_VERSION_SHA256
    puts "== ruby-#{RUBY_VERSION_PIN}.tar.gz already downloaded and verified"
    return
  end

  puts "== downloading ruby-#{RUBY_VERSION_PIN}.tar.gz"
  URI.parse(TARBALL_URL).open { |remote| File.binwrite(TARBALL_PATH, remote.read) }

  actual = Digest::SHA256.file(TARBALL_PATH).hexdigest
  return if actual == RUBY_VERSION_SHA256

  File.delete(TARBALL_PATH)
  abort "error: sha256 mismatch for ruby-#{RUBY_VERSION_PIN}.tar.gz\n" \
    "  expected: #{RUBY_VERSION_SHA256}\n  actual:   #{actual}"
end

def extract!
  if File.exist?(File.join(SOURCE_DIR, "configure"))
    puts "== ruby-#{RUBY_VERSION_PIN} already extracted"
    return
  end

  puts "== extracting ruby-#{RUBY_VERSION_PIN}.tar.gz"
  sh!("tar", "xzf", TARBALL_PATH, "-C", SRC_DIR, chdir: ROOT)
end

def install_dir_for(key) = File.join(BUILD_DIR, key, "install")

def build_dir_for(key) = File.join(BUILD_DIR, key, "build")

def stub_include_dir_for(key) = File.join(BUILD_DIR, key, "stub-include")

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
    "--without-openssl",
    "--without-psych",
    "--without-fiddle", # App Store review flags apps that can load arbitrary native code via dlopen/FFI; dropped for every target, not just iOS, so macOS and iOS stay built from the same flag set.
    "--with-out-ext=bigdecimal*,readline*,openssl*,psych*,fiddle*",
  ]
  configure_args << "--host=#{target[:host]}" if target[:host]
  # Cross-compiles need a base Ruby to run CRuby's own generator scripts during the build; check_host_ruby! already guarantees the host `ruby`'s minor version matches.
  configure_args << "--with-baseruby=#{RbConfig.ruby}" if target[:host]

  cflags = "-pipe -Os -fvisibility=hidden"
  env = {
    "CFLAGS" => cflags,
    target[:deployment_target_env] => target[:deployment_target],
  }
  # Cross-compiles (slice 2) can't rely on the toolchain's default SDK and must force it explicitly; a native build picks up Xcode's default.
  env["SDKROOT"] = sdk_path if target[:host]

  if target[:triple]
    write_vnode_stub!(key)
    env["CFLAGS"] = "#{cflags} -target #{target[:triple]} -isysroot #{sdk_path} -I#{stub_include_dir_for(key)}"
    # configure's own link probes need the target/sysroot too, not just the compile step.
    env["LDFLAGS"] = "-target #{target[:triple]} -isysroot #{sdk_path}"
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
  filelist_entries = [stripped, File.join(build_dir, "ext", "extinit.o")] + ext_archives + [
    File.join(build_dir, "enc", "encinit.o"),
    File.join(build_dir, "enc", "libenc.a"),
    File.join(build_dir, "enc", "libtrans.a"),
  ]
  filelist = "#{static_lib}.filelist"
  File.write(filelist, "#{filelist_entries.join("\n")}\n")

  puts "== merging statically-linked extensions into #{key}'s static lib"
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

  targets = TARGETS.select { |_, target| target[:enabled] }
  abort "error: no targets enabled in TARGETS" if targets.empty?

  targets.each do |key, target|
    puts "== target: #{key}"
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
  sanitize_rbconfig!(install_dir_for("macosx-arm64"))

  puts "== done -- static libs, headers, and stdlib installed under #{VENDOR_DIR}"
end

main if $PROGRAM_NAME == __FILE__
