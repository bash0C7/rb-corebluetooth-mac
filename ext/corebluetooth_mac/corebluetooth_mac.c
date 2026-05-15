#include <ruby.h>
#include <ruby/thread.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE eCbm, eState, ePerm, eTimeout, eConn, eDisco, eIO, eClosed;

// ---- error mapping ----

static VALUE error_class_for_tag(int32_t tag) {
    switch (tag) {
        case 1: return eState;
        case 2: return ePerm;
        case 3: return eTimeout;
        case 4: return eConn;
        case 5: return eDisco;
        case 6: return eIO;
        case 7: return eClosed;
        default: return eCbm;
    }
}

static void raise_with(int32_t tag, char *msg) {
    VALUE klass = error_class_for_tag(tag);
    VALUE m = rb_utf8_str_new_cstr(msg ? msg : "unknown error");
    if (msg) free(msg);
    rb_raise(klass, "%s", StringValueCStr(m));
}

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

// ---- initialize (state-blocking, releases GVL) ----

struct new_args { int32_t timeout_ms; int32_t tag; char *err; void *p; };

static void *new_no_gvl(void *data) {
    struct new_args *a = (struct new_args *)data;
    a->p = cbm_central_new(a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_central_init(VALUE self, VALUE timeout_ms_v) {
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct new_args a = { (int32_t)NUM2INT(timeout_ms_v), 0, NULL, NULL };
    rb_thread_call_without_gvl(new_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.p) raise_with(a.tag, a.err);
    DATA_PTR(self) = a.p;
    return self;
}

static VALUE rb_central_id(VALUE self) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    return LL2NUM(cbm_central_id(p));
}

// ---- scan (releases GVL while delegate fills results) ----

struct scan_args {
    void *p;
    const char *name;
    const char *services_json;
    int32_t timeout_ms;
    int32_t tag;
    char *err;
    char *result;
};

static void *scan_no_gvl(void *data) {
    struct scan_args *a = (struct scan_args *)data;
    a->result = cbm_central_scan(a->p, a->name, a->services_json, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_central_scan(VALUE self, VALUE name_v, VALUE services_json_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eClosed, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct scan_args a = {
        p,
        NIL_P(name_v) ? NULL : StringValueCStr(name_v),
        NIL_P(services_json_v) ? NULL : StringValueCStr(services_json_v),
        (int32_t)NUM2INT(timeout_ms_v),
        0, NULL, NULL
    };
    rb_thread_call_without_gvl(scan_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.err) raise_with(a.tag, a.err);
    if (!a.result) return rb_utf8_str_new_cstr("[]");
    VALUE s = rb_utf8_str_new_cstr(a.result);
    free(a.result);
    return s;
}

// ---- hello (still useful for smoke) ----

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
    rb_define_method(cNative, "initialize", rb_central_init, 1);
    rb_define_method(cNative, "central_id", rb_central_id,   0);
    rb_define_method(cNative, "scan",       rb_central_scan, 3);
}
