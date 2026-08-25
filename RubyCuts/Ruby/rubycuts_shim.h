#ifndef RUBYCUTS_SHIM_H
#define RUBYCUTS_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/// Boots the Ruby VM with `stdlib_path` as the sole `$LOAD_PATH` entry. Returns 0 on success, non-zero if the VM failed to boot. Safe to call more than once; later calls no-op.
int rubycuts_init(const char *stdlib_path);

/// Evaluates `code`, returning a malloc'd UTF-8 string the caller frees with `rubycuts_free`. On failure returns NULL and writes a malloc'd message to `*error_out`, which the caller also frees with `rubycuts_free`.
char *rubycuts_eval_to_string(const char *code, char **error_out);

/// Frees a string returned by this shim.
void rubycuts_free(char *string);

/// A native capability handler: `name` is the capability being invoked (e.g. `"device.clipboard.get"`), `args_json` is a JSON array of its arguments. On success returns a malloc'd one-element JSON array holding the result (`null` for a nil result); the caller frees it with `rubycuts_free`. On failure returns NULL and writes a malloc'd error message to `*error_out`, which the caller also frees with `rubycuts_free`.
typedef char *(*rubycuts_native_handler)(const char *name, const char *args_json, char **error_out);

/// Installs `handler` as the native bridge and defines `RubyCuts::Native.call(name, args_json)` (which dispatches to it) and `RubyCuts::NativeError < StandardError`. Safe to call more than once; a later call replaces the handler and reuses the already-defined module/class.
void rubycuts_install_native_bridge(rubycuts_native_handler handler);

#ifdef __cplusplus
}
#endif

#endif /* RUBYCUTS_SHIM_H */
