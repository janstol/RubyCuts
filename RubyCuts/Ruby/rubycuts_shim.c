#include "rubycuts_shim.h"

#include <ruby.h>
#include <stdlib.h>
#include <string.h>

// Tracks whether ruby_init() has already run. The Ruby VM cannot be re-initialized after ruby_cleanup(), and this shim never calls ruby_cleanup(), so this flag only guards against a redundant ruby_init().
static int g_rubycuts_initialized = 0;

int rubycuts_init(void) {
    if (g_rubycuts_initialized) {
        return 0;
    }

    // RUBY_INIT_STACK expands to a local variable declaration plus a call to ruby_init_stack(&that_variable), recording this frame's address as the bottom of the machine stack the GC scans. It is a macro built on __builtin_frame_address, not a function, so it has to be expanded here in C -- Swift cannot call it directly.
    RUBY_INIT_STACK;
    ruby_init();

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
