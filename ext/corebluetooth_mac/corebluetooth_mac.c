#include <ruby.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE rb_cbm_hello(VALUE self) {
    char *r = cbm_hello();
    if (!r) return Qnil;
    VALUE s = rb_utf8_str_new_cstr(r);
    free(r);
    return s;
}

void Init_corebluetooth_mac(void) {
    VALUE mod = rb_define_module("CoreBluetoothMac");
    rb_define_singleton_method(mod, "__hello", rb_cbm_hello, 0);
}
