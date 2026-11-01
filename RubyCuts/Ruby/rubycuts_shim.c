#include "rubycuts_shim.h"

#include <ruby.h>
#include <ruby/version.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Tracks whether ruby_init() has already run. The Ruby VM cannot be re-initialized after ruby_cleanup(), and this shim never calls ruby_cleanup(), so this flag only guards against a redundant ruby_init().
static int g_rubycuts_initialized = 0;

const char *rubycuts_ruby_version(void) {
    return ruby_version;
}

int rubycuts_init(const char *stdlib_path) {
    if (g_rubycuts_initialized) {
        return 0;
    }
    if (stdlib_path == NULL) {
        return 1;
    }

    // RUBY_INIT_STACK expands to a local variable declaration plus a call to ruby_init_stack(&that_variable), recording this frame's address as the bottom of the machine stack the GC scans. It is a macro built on __builtin_frame_address, not a function, so it has to be expanded here in C; Swift cannot call it directly.
    RUBY_INIT_STACK;
    ruby_init();

    // ruby_init() alone only runs Init_BareVM plus the core-class rb_call_inits() list;
    // that's not a complete boot. It never runs Init_ext() (which registers every
    // statically-linked C extension, stringio, zlib, json/ext, as require-able at
    // all), never loads the compiled builtin iseqs, never sets up the encoding database,
    // and never seeds $LOAD_PATH. All of that lives in ruby_opt_init(), reachable only
    // through ruby_options(). Passing "-e ''" makes ruby_options() do that setup work
    // without actually running a script: there's nothing to run, so its return value
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
    // time; it points at this machine's .build-cruby/.../install, present on the dev
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
// throw data crashes the process: rb_funcall hits `uncallable_object`, the
// resulting rb_raise -> rb_longjmp then SIGSEGVs inside the longjmp mechanics
// (seen via a repro running `return {}`). So the exception message is only
// extracted for TAG_RAISE; all other states get a synthesized message matching
// what `ruby -e` would raise (LocalJumpError: unexpected return, ...).
#define RC_TAG_RAISE 0x6

/// Copies `length` bytes into a fresh malloc'd, NUL-terminated buffer. Never
/// raises: plain C, no Ruby calls. `bytes` is NULL only if malloc failed.
static rubycuts_buffer rc_buffer_from_bytes(const char *bytes, long length) {
    rubycuts_buffer buffer = {NULL, 0};
    char *copy = malloc((size_t)length + 1);
    if (copy == NULL) return buffer;
    memcpy(copy, bytes, (size_t)length);
    copy[length] = '\0';
    buffer.bytes = copy;
    buffer.length = length;
    return buffer;
}

static rubycuts_buffer rc_buffer_from_cstr(const char *cstr) {
    return rc_buffer_from_bytes(cstr, (long)strlen(cstr));
}

/// Copies a Ruby String's bytes out by length. RSTRING_PTR/RSTRING_LEN are
/// plain field reads, so unlike StringValueCStr this can't raise, and an
/// embedded NUL survives instead of being rejected with an ArgumentError.
static rubycuts_buffer rc_buffer_from_string(VALUE string) {
    return rc_buffer_from_bytes(RSTRING_PTR(string), RSTRING_LEN(string));
}

/// `rb_protect` callback: `obj.to_s`. Can run arbitrary user Ruby (a
/// redefined `to_s`), so it must only ever be called under rb_protect.
static VALUE rc_as_string(VALUE obj) {
    return rb_obj_as_string(obj);
}

/// `rb_protect` callback: the fallback message for an exception whose own
/// `to_s` raised, built from its class name instead. Also run under
/// rb_protect, since even a class name lookup is a Ruby call.
static VALUE rc_unformattable_error_message(VALUE error) {
    VALUE message = rb_str_dup(rb_class_name(rb_obj_class(error)));
    rb_str_cat_cstr(message, " (its message raised while being formatted)");
    return message;
}

/// Returns the human-readable message for a nonzero protect `state`, as an
/// owned buffer. For TAG_RAISE the message comes from the raised exception's
/// `to_s`; for any other tag it is synthesized. Always clears `ec->errinfo`
/// (the throw data / exception) before returning, and never raises: every
/// Ruby call that could run user code goes through rb_protect, falling back
/// to the class name and then to a fixed string.
static rubycuts_buffer rc_error_message_for_state(int state) {
    if (state == RC_TAG_RAISE) {
        VALUE error = rb_errinfo();
        // Stash the exception in a Ruby global before clearing errinfo, so
        // Swift can still read its backtrace after this call returns. This
        // is a deliberate GC root holding exactly one exception, overwritten
        // on the next failed eval; see the other branch below, which sets it
        // to Qnil so a non-raise failure can't leak a stale backtrace from an
        // earlier raise.
        rb_gv_set("$rc_last_error", error);
        rb_set_errinfo(Qnil);
        if (error == Qnil) {
            return rc_buffer_from_cstr("unknown Ruby error");
        }

        int format_state = 0;
        VALUE message = rb_protect(rc_as_string, error, &format_state);
        if (format_state == 0) {
            return rc_buffer_from_string(message);
        }
        rb_set_errinfo(Qnil);

        message = rb_protect(rc_unformattable_error_message, error, &format_state);
        if (format_state == 0) {
            return rc_buffer_from_string(message);
        }
        rb_set_errinfo(Qnil);
        return rc_buffer_from_cstr("unknown Ruby error");
    }

    // A non-exception non-local exit. ec->errinfo is throw data, not an object;
    // clear it (a plain pointer store, safe) and synthesize a message. The
    // wording mirrors MRI's LocalJumpError messages for top-level jumps.
    // $rc_last_error is reset to Qnil here too: this failure has no exception
    // object, and without this the backtrace reader would otherwise surface
    // the trace of some earlier, unrelated raise.
    rb_gv_set("$rc_last_error", Qnil);
    rb_set_errinfo(Qnil);
    switch (state) {
        case 0x1: return rc_buffer_from_cstr("unexpected return");
        case 0x2: return rc_buffer_from_cstr("unexpected break");
        case 0x3: return rc_buffer_from_cstr("unexpected next");
        case 0x4: return rc_buffer_from_cstr("unexpected retry");
        case 0x5: return rc_buffer_from_cstr("unexpected redo");
        case 0x7: return rc_buffer_from_cstr("unexpected throw");
        case 0x8: return rc_buffer_from_cstr("fatal error");
        default: return rc_buffer_from_cstr("unexpected control flow");
    }
}

int rubycuts_eval(const char *code, rubycuts_buffer *output) {
    int state = 0;
    // rb_eval_string_protect, never rb_eval_string: a raised exception in rb_eval_string longjmps past this C frame (and the Swift frames above it), which is undefined behavior. The _protect variant reports failure through `state` instead, letting us return normally either way.
    VALUE result = rb_eval_string_protect(code, &state);

    // Converting the result runs user code too (a redefined `to_s`), so it
    // gets the same protection. A raise there lands in `state` and is
    // reported exactly like a raise from the eval itself.
    if (state == 0) {
        VALUE string = rb_protect(rc_as_string, result, &state);
        if (state == 0) {
            *output = rc_buffer_from_string(string);
            return 1;
        }
    }

    *output = rc_error_message_for_state(state);
    return 0;
}

void rubycuts_free(char *string) {
    free(string);
}

// The installed native handler, and the RubyCuts::NativeError class it raises
// through. Both are file-scope statics rather than something passed around:
// rc_native_call (a Ruby-callable C function) has no way to receive extra
// context beyond the VALUEs Ruby gives it, so the handler and error class have
// to be reachable some other way. g_native_error_class needs no
// rb_gc_register_address: once rb_define_class_under assigns it to a constant
// under RubyCuts, the module's own constant table keeps it alive.
static rubycuts_native_handler g_native_handler = NULL;
static VALUE g_native_error_class = Qnil;

// The exception class the cancellation hook raises through. Same rooting
// story as g_native_error_class: once rb_define_class_under assigns it to a
// constant under RubyCuts, the module's own constant table keeps it alive,
// so no rb_gc_register_address is needed.
static VALUE g_cancelled_class = Qnil;

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
    // rb_exc_raise: it longjmps past this frame, so nothing malloc'd may
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

    // Subclasses Exception, not StandardError: a bare `rescue => e` in user
    // code must not swallow a cancellation, the same reason MRI's own
    // Interrupt and SystemExit sit outside StandardError.
    if (g_cancelled_class == Qnil) {
        g_cancelled_class =
            rb_define_class_under(rubycuts_module, "Cancelled", rb_eException);
    }
}

// One run's cancellation request. Written from whichever thread cancels the
// run (atomic, no lock: the VM thread must never block on anything the
// cancelling thread might hold), read by rc_cancel_hook on the VM thread.
// Each run gets its own, so cancelling one run can never reach another: a
// queued run's request waits in its own struct until that run starts, and a
// late request for a finished run lands in a struct nothing reads any more.
struct rubycuts_run {
    _Atomic int cancel_requested;
};

rubycuts_run *rubycuts_run_create(void) {
    rubycuts_run *run = malloc(sizeof(rubycuts_run));
    if (run == NULL) return NULL;
    atomic_init(&run->cancel_requested, 0);
    return run;
}

void rubycuts_run_destroy(rubycuts_run *run) {
    free(run);
}

void rubycuts_run_cancel(rubycuts_run *run) {
    atomic_store(&run->cancel_requested, 1);
}

int rubycuts_run_is_cancelled(rubycuts_run *run) {
    return atomic_load(&run->cancel_requested);
}

// The run whose user code is executing right now, or NULL outside the hook
// window. VM-thread-only (set by enable/disable, read by the hook, all on the
// VM thread), so a plain pointer: other threads never look at it, they only
// write to their own run's flag.
static rubycuts_run *g_active_run = NULL;

// VM-thread-only, so a plain int: records whether the hook actually fired
// (raised) during the window it was installed. Read by
// rubycuts_cancel_hook_disable() to report back to Swift.
static int g_cancel_delivered = 0;

// Checked on every RUBY_EVENT_LINE/CALL/B_CALL event while installed. The
// fast path (not cancelled) is a pointer check plus one atomic load, so a
// non-cancelled run pays only predicted-not-taken branches per event.
//
// Raising at most once per window, via g_cancel_delivered, is what makes this
// one-shot: rb_raise unwinds back through this same event loop as it pops
// frames (running any `ensure` blocks along the way), and each of those is
// itself a LINE/CALL event. Without that guard, the hook would re-fire on
// every one of them.
static void rc_cancel_hook(
    rb_event_flag_t evflag, VALUE data, VALUE self, ID mid, VALUE klass) {
    rubycuts_run *run = g_active_run;
    if (run == NULL || g_cancel_delivered) return;
    if (!atomic_load(&run->cancel_requested)) return;
    g_cancel_delivered = 1;
    rb_raise(g_cancelled_class, "run cancelled");
}

void rubycuts_cancel_hook_enable(rubycuts_run *run) {
    g_active_run = run;
    g_cancel_delivered = 0;
    rb_add_event_hook(
        rc_cancel_hook,
        RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_B_CALL,
        Qnil);
}

int rubycuts_cancel_hook_disable(void) {
    rb_remove_event_hook(rc_cancel_hook);
    g_active_run = NULL;
    return g_cancel_delivered;
}
