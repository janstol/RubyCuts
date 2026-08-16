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

#ifdef __cplusplus
}
#endif

#endif /* RUBYCUTS_SHIM_H */
