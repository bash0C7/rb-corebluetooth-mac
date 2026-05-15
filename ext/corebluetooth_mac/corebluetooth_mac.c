#include <ruby.h>
#include <ruby/thread.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE eCbm, eState, ePerm, eTimeout, eConn, eDisco, eIO, eClosed;

// ---- TypedData for Central ----

static void central_dfree(void *p) {
    if (p) cbm_central_free(p);
}

static const rb_data_type_t central_dt = {
    "CoreBluetoothMac::Native",
    { NULL, central_dfree, NULL, },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE rb_central_alloc(VALUE klass) {
    return TypedData_Wrap_Struct(klass, &central_dt, NULL);
}

// ---- helpers ----

static VALUE rb_cbm_hello(VALUE self) {
    char *r = cbm_hello();
    if (!r) return Qnil;
    VALUE s = rb_utf8_str_new_cstr(r);
    free(r);
    return s;
}

// ---- Init ----

void Init_corebluetooth_mac(void) {
    VALUE mod = rb_define_module("CoreBluetoothMac");
    eCbm     = rb_const_get(mod, rb_intern("Error"));
    eState   = rb_const_get(mod, rb_intern("StateError"));
    ePerm    = rb_const_get(mod, rb_intern("PermissionError"));
    eTimeout = rb_const_get(mod, rb_intern("TimeoutError"));
    eConn    = rb_const_get(mod, rb_intern("ConnectionError"));
    eDisco   = rb_const_get(mod, rb_intern("DiscoveryError"));
    eIO      = rb_const_get(mod, rb_intern("IOError"));
    eClosed  = rb_const_get(mod, rb_intern("ClosedError"));

    rb_define_singleton_method(mod, "__hello", rb_cbm_hello, 0);

    VALUE cNative = rb_define_class_under(mod, "Native", rb_cObject);
    rb_define_alloc_func(cNative, rb_central_alloc);
}
