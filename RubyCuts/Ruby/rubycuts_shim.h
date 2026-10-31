#ifndef RUBYCUTS_SHIM_H
#define RUBYCUTS_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/// Boots the Ruby VM with `stdlib_path` as the sole `$LOAD_PATH` entry. Returns 0 on success, non-zero if the VM failed to boot. Safe to call more than once; later calls no-op.
int rubycuts_init(const char *stdlib_path);

/// A malloc'd byte buffer handed from the shim to Swift. `bytes` may contain NUL bytes, so always read exactly `length` bytes rather than treating it as a C string (it is NUL-terminated as well, for convenience). `bytes` is NULL only if allocation failed. Free with `rubycuts_free(buffer.bytes)`.
typedef struct {
    char *bytes;
    long length;
} rubycuts_buffer;

/// Evaluates `code` and never lets a Ruby exception or jump escape into the caller. Returns 1 on success, with the result's `to_s` in `*output`. Returns 0 on failure (a parse error, a raise, a top-level jump, or a result whose `to_s` itself raised), with a human-readable error message in `*output`. Either way the caller frees `output->bytes` with `rubycuts_free`.
int rubycuts_eval(const char *code, rubycuts_buffer *output);

/// Frees a string returned by this shim.
void rubycuts_free(char *string);

/// A native capability handler: `name` is the capability being invoked (e.g. `"device.clipboard.get"`), `args_json` is a JSON array of its arguments. On success returns a malloc'd one-element JSON array holding the result (`null` for a nil result); the caller frees it with `rubycuts_free`. On failure returns NULL and writes a malloc'd error message to `*error_out`, which the caller also frees with `rubycuts_free`.
typedef char *(*rubycuts_native_handler)(const char *name, const char *args_json, char **error_out);

/// Installs `handler` as the native bridge and defines `RubyCuts::Native.call(name, args_json)` (which dispatches to it) and `RubyCuts::NativeError < StandardError`. Safe to call more than once; a later call replaces the handler and reuses the already-defined module/class.
void rubycuts_install_native_bridge(rubycuts_native_handler handler);

/// One run's cancellation state. Opaque: created and destroyed by the owner of the run, cancelled from any thread, and read by the VM thread's event hook only while that run is the active one.
typedef struct rubycuts_run rubycuts_run;

/// Allocates cancellation state for one run, not yet cancelled. Returns NULL if allocation failed. Free with `rubycuts_run_destroy` once the run has finished and nothing can cancel it any more.
rubycuts_run *rubycuts_run_create(void);

/// Frees state from `rubycuts_run_create`.
void rubycuts_run_destroy(rubycuts_run *run);

/// Marks `run` as cancelled. Thread-safe and non-blocking: callable from any thread, before the run starts, while it executes, or after it ends. Only ever affects `run` itself, never another run.
void rubycuts_run_cancel(rubycuts_run *run);

/// Returns 1 if `run` has been cancelled, 0 otherwise. Thread-safe.
int rubycuts_run_is_cancelled(rubycuts_run *run);

/// Installs the cancellation event hook for `run`, which is the active run until `rubycuts_cancel_hook_disable`. VM thread only.
void rubycuts_cancel_hook_enable(rubycuts_run *run);

/// Removes the hook, clears the active run, and returns 1 if the hook actually raised during the window it was installed, 0 otherwise. VM thread only.
int rubycuts_cancel_hook_disable(void);

#ifdef __cplusplus
}
#endif

#endif /* RUBYCUTS_SHIM_H */
