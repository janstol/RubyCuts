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

// RUBY_TAG_RAISE (0x6) is the only rb_eval_string_protect state where
// rb_errinfo() holds a real Ruby exception object. The enum `ruby_tag_type` is
// in CRuby's internal vm_core.h, not exposed by the public <ruby.h>, so the
// value is pinned here. It has been stable across the entire CRuby 3.x ABI
// (and since 1.9); this project pins CRuby 3.4.9 and updates it by hand, so a
// bump is the place to re-check this constant.
//
// Why this matters: for every other nonzero state (return/break/next/redo/
// retry/throw/fatal at the top level of the eval'd string), ec->errinfo points
// at internal throw data, NOT a Ruby object. Calling rb_obj_as_string on that
// throw data crashes the process -- rb_funcall hits `uncallable_object`, the
// resulting rb_raise -> rb_longjmp then SIGSEGVs inside the longjmp mechanics
// (seen via a repro running `return {}`). So the exception message is only
// extracted for TAG_RAISE; all other states get a synthesized message matching
// what `ruby -e` would raise (LocalJumpError: unexpected return, ...).
#define RC_TAG_RAISE 0x6

/// Returns a malloc'd human-readable message for a nonzero protect `state`.
/// The caller frees it with `rubycuts_free`. For TAG_RAISE the message comes from
/// the raised exception's `to_s`; for any other tag it is synthesized. Always
/// clears `ec->errinfo` (the throw data / exception) before returning.
static char *rc_error_message_for_state(int state) {
    if (state == RC_TAG_RAISE) {
        VALUE error = rb_errinfo();
        // Stash the exception in a Ruby global before clearing errinfo, so
        // Swift can still read its backtrace after this call returns. This
        // is a deliberate GC root holding exactly one exception, overwritten
        // on the next failed eval -- see rc_error_message_for_state's other
        // branch, which sets it to Qnil so a non-raise failure can't leak a
        // stale backtrace from an earlier raise.
        rb_gv_set("$rc_last_error", error);
        rb_set_errinfo(Qnil);
        if (error != Qnil) {
            VALUE message = rb_obj_as_string(error);
            return strdup(StringValueCStr(message));
        }
        return strdup("unknown Ruby error");
    }

    // A non-exception non-local exit. ec->errinfo is throw data, not an object
    // -- clear it (a plain pointer store, safe) and synthesize a message. The
    // wording mirrors MRI's LocalJumpError messages for top-level jumps.
    // $rc_last_error is reset to Qnil here too: this failure has no exception
    // object, and without this the backtrace reader would otherwise surface
    // the trace of some earlier, unrelated raise.
    rb_gv_set("$rc_last_error", Qnil);
    rb_set_errinfo(Qnil);
    switch (state) {
        case 0x1: return strdup("unexpected return");
        case 0x2: return strdup("unexpected break");
        case 0x3: return strdup("unexpected next");
        case 0x4: return strdup("unexpected retry");
        case 0x5: return strdup("unexpected redo");
        case 0x7: return strdup("unexpected throw");
        case 0x8: return strdup("fatal error");
        default: return strdup("unexpected control flow");
    }
}

char *rubycuts_eval_to_string(const char *code, char **error_out) {
    int state = 0;
    // rb_eval_string_protect, never rb_eval_string: a raised exception in rb_eval_string longjmps past this C frame (and the Swift frames above it), which is undefined behavior. The _protect variant reports failure through `state` instead, letting us return normally either way.
    VALUE result = rb_eval_string_protect(code, &state);

    if (state != 0) {
        if (error_out != NULL) {
            *error_out = rc_error_message_for_state(state);
        } else {
            // No caller interest in the message, but still clear errinfo so the
            // throw data / exception doesn't leak into the next eval.
            rb_set_errinfo(Qnil);
        }
        return NULL;
    }

    VALUE string = rb_obj_as_string(result);
    return strdup(StringValueCStr(string));
}

void rubycuts_free(char *string) {
    free(string);
}

// The installed native handler, and the RubyCuts::NativeError class it raises
// through. Both are file-scope statics rather than something passed around --
// rc_native_call (a Ruby-callable C function) has no way to receive extra
// context beyond the VALUEs Ruby gives it, so the handler and error class have
// to be reachable some other way. g_native_error_class needs no
// rb_gc_register_address: once rb_define_class_under assigns it to a constant
// under RubyCuts, the module's own constant table keeps it alive.
static rubycuts_native_handler g_native_handler = NULL;
static VALUE g_native_error_class = Qnil;

static VALUE rc_native_call(VALUE self, VALUE name, VALUE args_json) {
    if (g_native_handler == NULL) {
        rb_raise(rb_eRuntimeError, "RubyCuts::Native bridge is not installed");
    }

    const char *name_cstr = StringValueCStr(name);
    const char *args_json_cstr = StringValueCStr(args_json);

    char *error_out = NULL;
    char *result = g_native_handler(name_cstr, args_json_cstr, &error_out);

    if (result != NULL) {
        VALUE ruby_result = rb_utf8_str_new_cstr(result);
        free(result);
        return ruby_result;
    }

    // Copy the error into a Ruby string, and free the C buffer, before
    // rb_exc_raise -- it longjmps past this frame, so nothing malloc'd may
    // still be owned here when it fires. Same hazard rc_error_message_for_state
    // documents around rb_eval_string_protect.
    VALUE message = error_out != NULL
        ? rb_utf8_str_new_cstr(error_out)
        : rb_utf8_str_new_cstr("unknown native bridge error");
    if (error_out != NULL) {
        free(error_out);
    }
    VALUE exception = rb_exc_new_str(g_native_error_class, message);
    rb_exc_raise(exception);
}

void rubycuts_install_native_bridge(rubycuts_native_handler handler) {
    g_native_handler = handler;

    // rb_define_module/rb_define_module_under/rb_define_class_under all reopen
    // an existing definition rather than redefining it, so a second call here
    // (bootIfNeeded runs this on every eval) just swaps the handler pointer.
    VALUE rubycuts_module = rb_define_module("RubyCuts");
    VALUE native_module = rb_define_module_under(rubycuts_module, "Native");
    rb_define_module_function(native_module, "call", rc_native_call, 2);

    if (g_native_error_class == Qnil) {
        g_native_error_class =
            rb_define_class_under(rubycuts_module, "NativeError", rb_eStandardError);
    }
}
