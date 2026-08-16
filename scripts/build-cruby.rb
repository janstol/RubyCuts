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

RUBY_VERSION_PIN = "3.4.9"
RUBY_VERSION_SHA256 = "7bb4d4f5e807cc27251d14d9d6086d182c5b25875191e44ab15b709cd7a7dd9c"
RUBY_SERIES = RUBY_VERSION_PIN.split(".")[0, 2].join(".") # "3.4", the cache.ruby-lang.org series dir
RUBY_ABI_VERSION = "#{RUBY_SERIES}.0" # "3.4.0", the header dir name CRuby installs under

TARBALL_URL = "https://cache.ruby-lang.org/pub/ruby/#{RUBY_SERIES}/ruby-#{RUBY_VERSION_PIN}.tar.gz"
TARBALL_PATH = File.join(SRC_DIR, "ruby-#{RUBY_VERSION_PIN}.tar.gz")
SOURCE_DIR = File.join(SRC_DIR, "ruby-#{RUBY_VERSION_PIN}")

# One row per SDK/arch this project can build for. Only macosx-arm64 is enabled in slice 1 (see docs/embedding-cruby.md); the iphoneos and iphonesimulator rows land in slice 2 with their own flag set (a --host triple, --without-fiddle, the syscall/backtrace autoconf overrides). The shape of this table -- not just the one row -- is deliberate: slice 2 should be able to add rows without restructuring the build functions below.
TARGETS = {
  "macosx-arm64" => {
    enabled: true,
    sdk: "macosx",
    arch: "arm64",
    lib_subdir: "macosx", # matches OTHER_LDFLAGS[sdk=macosx*] in Config/Shared.xcconfig
    deployment_target_env: "MACOSX_DEPLOYMENT_TARGET",
    deployment_target: "15.0",
    host: nil, # native build: the host toolchain already targets macOS arm64
  },
}.freeze

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

def find_static_lib(install_dir)
  Dir.glob(File.join(install_dir, "lib", "lib*-static.a")).first
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
    "--with-out-ext=bigdecimal*,readline*,openssl*,psych*",
  ]
  configure_args << "--host=#{target[:host]}" if target[:host]

  env = {
    "CFLAGS" => "-pipe -Os -fvisibility=hidden",
    target[:deployment_target_env] => target[:deployment_target],
  }
  # Cross-compiles (slice 2) can't rely on the toolchain's default SDK and must force it explicitly; a native build picks up Xcode's default.
  env["SDKROOT"] = sdk_path if target[:host]

  puts "== configuring #{key}"
  sh!(File.join(SOURCE_DIR, "configure"), *configure_args, chdir: build_dir, env: env)

  puts "== building #{key} (this takes 10-20 minutes)"
  jobs = capture!("sysctl", "-n", "hw.ncpu").strip
  sh!("make", "-j#{jobs}", chdir: build_dir, env: env)
  sh!("make", "install", chdir: build_dir, env: env)
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
  include_dest = File.join(VENDOR_DIR, "include")
  FileUtils.mkdir_p(include_dest)

  # Ruby installs generic headers directly under ruby-3.4.0/, plus one arch-specific subdirectory (e.g. ruby-3.4.0/arm64-darwin24/) holding just ruby/config.h. We flatten both into a single Vendor/CRuby/include/ so a plain -I$(CRUBY_DIR)/include finds everything. Slice 1 builds one arch, so overlaying that one config.h is safe; a multi-arch build (slice 2) will need this to become a small dispatching config.h that #ifdefs to an arch-specific header instead of a straight copy -- see the seam noted in Config/Shared.xcconfig.
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

def main
  check_host_ruby!

  if ARGV.include?("--clean")
    puts "== --clean: removing #{BUILD_DIR} and #{VENDOR_DIR}"
    FileUtils.rm_rf(BUILD_DIR)
    FileUtils.rm_rf(VENDOR_DIR)
  end

  download_and_verify!
  extract!

  targets = TARGETS.select { |_, target| target[:enabled] }
  abort "error: no targets enabled in TARGETS" if targets.empty?

  targets.each do |key, target|
    puts "== target: #{key}"
    configure_and_make!(key, target)
    install_artifacts!(key, target)
  end

  puts "== done -- static libs and headers installed under #{VENDOR_DIR}"
end

main if $PROGRAM_NAME == __FILE__
