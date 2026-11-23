#include <ruby.h>

void Init_native(void) {
    VALUE greeting = rb_define_module("Greeting");
    rb_define_const(greeting, "PREFIX", rb_str_new_cstr("hello "));
}
