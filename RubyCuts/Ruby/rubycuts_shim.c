#include "rubycuts_shim.h"

#include <ruby.h>
#include <stdlib.h>
#include <string.h>

// Tracks whether ruby_init() has already run. The Ruby VM cannot be re-initialized after ruby_cleanup(), and this shim never calls ruby_cleanup(), so this flag only guards against a redundant ruby_init().
static int g_rubycuts_initialized = 0;

int rubycuts_init(const char *stdlib_path) {
    if (g_rubycuts_initialized) {
        return 0;
    }
    if (stdlib_path == NULL) {
        return 1;
    }

    // RUBY_INIT_STACK expands to a local variable declaration plus a call to ruby_init_stack(&that_variable), recording this frame's address as the bottom of the machine stack the GC scans. It is a macro built on __builtin_frame_address, not a function, so it has to be expanded here in C -- Swift cannot call it directly.
    RUBY_INIT_STACK;
    ruby_init();

    // ruby_init() alone only runs Init_BareVM plus the core-class rb_call_inits() list --
    // that's not a complete boot. It never runs Init_ext() (which registers every
    // statically-linked C extension -- stringio, zlib, json/ext -- as require-able at
    // all), never loads the compiled builtin iseqs, never sets up the encoding database,
    // and never seeds $LOAD_PATH. All of that lives in ruby_opt_init(), reachable only
    // through ruby_options(). Passing "-e ''" makes ruby_options() do that setup work
    // without actually running a script -- there's nothing to run, so its return value
    // (an opaque node for ruby_run_node()) is discarded.
    //
    // argv[0] is NULL, and every argv element points at a writable (non-literal) buffer:
    // ruby_options() mutates argv in place (ruby_setproctitle(), $0=), which is undefined
    // behavior against a string literal's read-only storage.
    char disable_gems_arg[] = "--disable-gems";
    char e_flag_arg[] = "-e";
    char e_script_arg[] = "";
    char *argv[] = {NULL, disable_gems_arg, e_flag_arg, e_script_arg};
    int argc = (int)(sizeof(argv) / sizeof(argv[0]));
    ruby_options(argc, argv);

    // ruby_init_loadpath() (run as part of ruby_options() above) seeds $LOAD_PATH from
    // ruby_exec_prefix, a compile-time constant baked into verconf.h at cross-compile
    // time -- it points at this machine's .build-cruby/.../install, present on the dev
    // Mac and absent on a device or simulator. Clear those stale entries and seed the
    // one path that actually ships in the app bundle, rather than layering stdlib_path
    // on top of them where it'd be masked by (or mask) the wrong tree.
    VALUE load_path = rb_gv_get("$LOAD_PATH");
    rb_ary_clear(load_path);
    rb_ary_push(load_path, rb_filesystem_str_new_cstr(stdlib_path));

    ruby_script("rubycuts");

    g_rubycuts_initialized = 1;
    return 0;
}

char *rubycuts_eval_to_string(const char *code, char **error_out) {
    int state = 0;
    // rb_eval_string_protect, never rb_eval_string: a raised exception in rb_eval_string longjmps past this C frame (and the Swift frames above it), which is undefined behavior. The _protect variant reports failure through `state` instead, letting us return normally either way.
    VALUE result = rb_eval_string_protect(code, &state);

    if (state != 0) {
        VALUE error = rb_errinfo();
        rb_set_errinfo(Qnil);
        if (error_out != NULL) {
            VALUE message = rb_obj_as_string(error);
            *error_out = strdup(StringValueCStr(message));
        }
        return NULL;
    }

    VALUE string = rb_obj_as_string(result);
    return strdup(StringValueCStr(string));
}

void rubycuts_free(char *string) {
    free(string);
}
