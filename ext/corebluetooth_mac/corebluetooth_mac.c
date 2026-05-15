#include <ruby.h>
#include <ruby/thread.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE eErrorClass;

// ---- error raise ----

// NOTE: Tag-based domain dispatch was removed here — domain info will be
// re-introduced via the JSON envelope in Plan Task 3. For Task 1 the C bridge
// raises the single merged Error class with message only.
static void raise_with(char *msg) {
    VALUE m = rb_utf8_str_new_cstr(msg ? msg : "unknown error");
    if (msg) free(msg);
    rb_raise(eErrorClass, "%s", StringValueCStr(m));
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
    if (!a.p) raise_with(a.err);
    DATA_PTR(self) = a.p;
    return self;
}

static VALUE rb_central_id(VALUE self) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
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
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct scan_args a = {
        p,
        NIL_P(name_v) ? NULL : StringValueCStr(name_v),
        NIL_P(services_json_v) ? NULL : StringValueCStr(services_json_v),
        (int32_t)NUM2INT(timeout_ms_v),
        0, NULL, NULL
    };
    rb_thread_call_without_gvl(scan_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.err) raise_with(a.err);
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

struct connect_args {
    void *p; const char *id; int32_t timeout_ms;
    int32_t tag; char *err; int32_t ok;
};

static void *connect_no_gvl(void *data) {
    struct connect_args *a = (struct connect_args *)data;
    a->ok = cbm_central_connect(a->p, a->id, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_central_connect(VALUE self, VALUE id_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct connect_args a = { p, StringValueCStr(id_v), (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0 };
    rb_thread_call_without_gvl(connect_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.ok) raise_with(a.err);
    return Qtrue;
}

static VALUE rb_central_disconnect(VALUE self, VALUE id_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    int32_t tag = 0; char *err = NULL;
    int32_t ok = cbm_central_disconnect(p, StringValueCStr(id_v), &tag, &err);
    (void)tag;
    if (!ok) raise_with(err);
    return Qtrue;
}

static VALUE rb_peripheral_state(VALUE self, VALUE id_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    char *r = cbm_peripheral_state(p, StringValueCStr(id_v));
    VALUE s = rb_utf8_str_new_cstr(r ? r : "unknown");
    if (r) free(r);
    return ID2SYM(rb_intern(StringValueCStr(s)));
}

struct disco_svc_args {
    void *p; const char *id; int32_t timeout_ms;
    int32_t tag; char *err; char *result;
};

static void *disco_svc_no_gvl(void *data) {
    struct disco_svc_args *a = (struct disco_svc_args *)data;
    a->result = cbm_peripheral_discover_services(a->p, a->id, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_peripheral_discover_services(VALUE self, VALUE id_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct disco_svc_args a = { p, StringValueCStr(id_v), (int32_t)NUM2INT(timeout_ms_v), 0, NULL, NULL };
    rb_thread_call_without_gvl(disco_svc_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.err) raise_with(a.err);
    VALUE s = rb_utf8_str_new_cstr(a.result ? a.result : "[]");
    if (a.result) free(a.result);
    return s;
}

struct disco_ch_args {
    void *p; const char *id; const char *svc_uuid; int32_t timeout_ms;
    int32_t tag; char *err; char *result;
};

static void *disco_ch_no_gvl(void *data) {
    struct disco_ch_args *a = (struct disco_ch_args *)data;
    a->result = cbm_service_discover_characteristics(a->p, a->id, a->svc_uuid, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_service_discover_characteristics(VALUE self, VALUE id_v, VALUE svc_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct disco_ch_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, NULL
    };
    rb_thread_call_without_gvl(disco_ch_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.err) raise_with(a.err);
    VALUE s = rb_utf8_str_new_cstr(a.result ? a.result : "[]");
    if (a.result) free(a.result);
    return s;
}

struct read_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; int32_t tag; char *err; int32_t len;
    unsigned char *buf;
};

static void *read_no_gvl(void *data) {
    struct read_args *a = (struct read_args *)data;
    a->buf = cbm_characteristic_read(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->len, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_read(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct read_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0, NULL
    };
    rb_thread_call_without_gvl(read_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.buf) raise_with(a.err);
    // Return a mutable binary String so callers can chain `.force_encoding("UTF-8")`
    // without `.dup` (matches Socket#read / IO#read conventions).
    VALUE s = rb_str_new((const char *)a.buf, a.len);
    free(a.buf);
    return s;
}

struct write_args {
    void *p; const char *id; const char *svc; const char *ch;
    const unsigned char *buf; int32_t buf_len;
    int32_t with_response; int32_t timeout_ms;
    int32_t tag; char *err; int32_t ok;
};

static void *write_no_gvl(void *data) {
    struct write_args *a = (struct write_args *)data;
    a->ok = cbm_characteristic_write(a->p, a->id, a->svc, a->ch,
                                     a->buf, a->buf_len, a->with_response, a->timeout_ms,
                                     &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_write(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v,
                                     VALUE data_v, VALUE with_response_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    StringValue(data_v);
    Check_Type(with_response_v, T_FIXNUM);
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct write_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (const unsigned char *)RSTRING_PTR(data_v), (int32_t)RSTRING_LEN(data_v),
        (int32_t)NUM2INT(with_response_v), (int32_t)NUM2INT(timeout_ms_v),
        0, NULL, 0
    };
    rb_thread_call_without_gvl(write_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.ok) raise_with(a.err);
    return Qnil;
}

struct subscribe_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; int32_t tag; char *err; int64_t sub_id;
};

static void *subscribe_no_gvl(void *data) {
    struct subscribe_args *a = (struct subscribe_args *)data;
    a->sub_id = cbm_characteristic_subscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_subscribe(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct subscribe_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0
    };
    rb_thread_call_without_gvl(subscribe_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (a.sub_id == 0) raise_with(a.err);
    return LL2NUM(a.sub_id);
}

struct unsubscribe_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; int32_t tag; char *err; int32_t ok;
};

static void *unsubscribe_no_gvl(void *data) {
    struct unsubscribe_args *a = (struct unsubscribe_args *)data;
    a->ok = cbm_characteristic_unsubscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->tag, &a->err);
    return NULL;
}

static VALUE rb_characteristic_unsubscribe(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct unsubscribe_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, 0
    };
    rb_thread_call_without_gvl(unsubscribe_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.ok) raise_with(a.err);
    return Qnil;
}

// ---- Module-level subscription functions (operate on integer ids) ----

struct next_args {
    int64_t sub_id; int32_t timeout_ms;
    int32_t closed; int32_t len; unsigned char *buf;
};

static void *next_no_gvl(void *data) {
    struct next_args *a = (struct next_args *)data;
    a->buf = cbm_subscription_next_value(a->sub_id, a->timeout_ms, &a->closed, &a->len);
    return NULL;
}

static VALUE rb_subscription_next_value(VALUE self, VALUE central_id_v, VALUE sub_id_v, VALUE timeout_ms_v) {
    (void)central_id_v;  // reserved for future multi-central isolation
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct next_args a = { (int64_t)NUM2LL(sub_id_v), (int32_t)NUM2INT(timeout_ms_v), 0, 0, NULL };
    rb_thread_call_without_gvl(next_no_gvl, &a, RUBY_UBF_IO, NULL);
    if (!a.buf) {
        return Qnil;  // timeout or closed-empty
    }
    // Mutable binary String, same convention as characteristic_read — callers
    // can chain `.force_encoding("UTF-8")` without `.dup` (matches Socket#read).
    VALUE s = rb_str_new((const char *)a.buf, a.len);
    free(a.buf);
    return s;
}

static VALUE rb_subscription_close(VALUE self, VALUE central_id_v, VALUE sub_id_v) {
    (void)central_id_v;
    cbm_subscription_close((int64_t)NUM2LL(sub_id_v));
    return Qnil;
}

// ---- Init ----

void Init_corebluetooth_mac(void) {
    VALUE mod = rb_define_module("CoreBluetoothMac");
    // The Ruby-side `errors.rb` is required by `corebluetooth_mac.rb` before
    // this native extension is loaded, so `CoreBluetoothMac::Error` is defined.
    eErrorClass = rb_const_get(mod, rb_intern("Error"));

    rb_define_singleton_method(mod, "__hello", rb_cbm_hello, 0);

    VALUE cNative = rb_define_class_under(mod, "Native", rb_cObject);
    rb_define_alloc_func(cNative, rb_central_alloc);
    rb_define_method(cNative, "initialize", rb_central_init, 1);
    rb_define_method(cNative, "central_id", rb_central_id,   0);
    rb_define_method(cNative, "scan",       rb_central_scan, 3);
    rb_define_method(cNative, "connect",          rb_central_connect,    2);
    rb_define_method(cNative, "disconnect",       rb_central_disconnect, 1);
    rb_define_method(cNative, "peripheral_state", rb_peripheral_state,   1);
    rb_define_method(cNative, "discover_services",        rb_peripheral_discover_services,       2);
    rb_define_method(cNative, "discover_characteristics", rb_service_discover_characteristics,   3);
    rb_define_method(cNative, "characteristic_read",      rb_characteristic_read,                4);
    rb_define_method(cNative, "characteristic_write",     rb_characteristic_write,               6);
    rb_define_method(cNative, "characteristic_subscribe",   rb_characteristic_subscribe,   4);
    rb_define_method(cNative, "characteristic_unsubscribe", rb_characteristic_unsubscribe, 4);

    rb_define_module_function(mod, "__subscription_next_value", rb_subscription_next_value, 3);
    rb_define_module_function(mod, "__subscription_close",      rb_subscription_close,      2);
}
