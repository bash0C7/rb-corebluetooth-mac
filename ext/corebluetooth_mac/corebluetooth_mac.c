#include <ruby.h>
#include <ruby/thread.h>
#include <stdlib.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE eErrorClass;

// ---- envelope parsing ----
//
// Every Swift→C string return is a JSON envelope:
//   {"ok": true,  "data": <payload-or-null>}
//   {"ok": false, "error": {"domain","code","code_name","message"}}
// `parse_envelope_str` parses the JSON, raises CoreBluetoothMac::Error on
// `ok: false`, or returns the `data` Ruby VALUE on `ok: true`.
// `parse_envelope_freed` is the common wrapper that also frees the C string.

__attribute__((noreturn))
static void raise_from_envelope_error(VALUE error_hash) {
    VALUE domain_v    = rb_hash_aref(error_hash, rb_str_new_cstr("domain"));
    VALUE code_v      = rb_hash_aref(error_hash, rb_str_new_cstr("code"));
    VALUE code_name_v = rb_hash_aref(error_hash, rb_str_new_cstr("code_name"));
    VALUE message_v   = rb_hash_aref(error_hash, rb_str_new_cstr("message"));

    if (NIL_P(message_v)) message_v = rb_str_new_cstr("unknown error");

    // Build kwargs hash. `domain` is always a symbol; `code` is integer or nil;
    // `code_name` is symbol or nil. All other shapes are tolerated as best-effort.
    VALUE kwargs = rb_hash_new();
    if (!NIL_P(domain_v)) {
        VALUE dsym = rb_funcall(domain_v, rb_intern("to_sym"), 0);
        rb_hash_aset(kwargs, ID2SYM(rb_intern("domain")), dsym);
    } else {
        rb_hash_aset(kwargs, ID2SYM(rb_intern("domain")), ID2SYM(rb_intern("validation")));
    }
    rb_hash_aset(kwargs, ID2SYM(rb_intern("code")), code_v);
    if (!NIL_P(code_name_v)) {
        VALUE csym = rb_funcall(code_name_v, rb_intern("to_sym"), 0);
        rb_hash_aset(kwargs, ID2SYM(rb_intern("code_name")), csym);
    } else {
        rb_hash_aset(kwargs, ID2SYM(rb_intern("code_name")), Qnil);
    }

    VALUE args[2];
    args[0] = message_v;
    args[1] = kwargs;
    VALUE exc = rb_funcallv_kw(eErrorClass, rb_intern("new"), 2, args, RB_PASS_KEYWORDS);
    rb_exc_raise(exc);
}

// Parse a JSON envelope and either raise (on ok: false) or return the data field.
static VALUE parse_envelope_str(const char *json) {
    if (!json) {
        rb_raise(eErrorClass, "internal: nil envelope from native bridge");
    }
    VALUE str = rb_utf8_str_new_cstr(json);
    VALUE json_mod = rb_const_get(rb_cObject, rb_intern("JSON"));
    VALUE parsed = rb_funcall(json_mod, rb_intern("parse"), 1, str);
    VALUE ok = rb_hash_aref(parsed, rb_str_new_cstr("ok"));
    if (RTEST(ok)) {
        return rb_hash_aref(parsed, rb_str_new_cstr("data"));
    }
    VALUE err = rb_hash_aref(parsed, rb_str_new_cstr("error"));
    if (NIL_P(err)) {
        rb_raise(eErrorClass, "malformed envelope: %s", json);
    }
    raise_from_envelope_error(err);
    return Qnil; // unreachable
}

struct parse_ensure_args { const char *json; char *to_free; };

static VALUE parse_envelope_body(VALUE p) {
    struct parse_ensure_args *a = (struct parse_ensure_args *)p;
    return parse_envelope_str(a->json);
}

static VALUE parse_envelope_ensure(VALUE p) {
    struct parse_ensure_args *a = (struct parse_ensure_args *)p;
    if (a->to_free) free(a->to_free);
    return Qnil;
}

// Convenience: parse-and-free. Frees `json` regardless of raise/return.
static VALUE parse_envelope_freed(char *json) {
    if (!json) {
        rb_raise(eErrorClass, "internal: nil envelope from native bridge");
    }
    struct parse_ensure_args a = { json, json };
    return rb_ensure(parse_envelope_body, (VALUE)&a, parse_envelope_ensure, (VALUE)&a);
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

struct new_args { int32_t timeout_ms; char *envelope; void *p; };

static void *new_no_gvl(void *data) {
    struct new_args *a = (struct new_args *)data;
    a->p = cbm_central_new(a->timeout_ms, &a->envelope);
    return NULL;
}

static VALUE rb_central_init(VALUE self, VALUE timeout_ms_v) {
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct new_args a = { (int32_t)NUM2INT(timeout_ms_v), NULL, NULL };
    rb_thread_call_without_gvl(new_no_gvl, &a, RUBY_UBF_IO, NULL);
    // parse_envelope_freed raises on ok=false; on ok=true it returns the data
    // payload (which is nil for cbm_central_new on success).
    (void)parse_envelope_freed(a.envelope);
    if (!a.p) rb_raise(eErrorClass, "internal: envelope ok but central pointer is null");
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
    char *envelope;
};

static void *scan_no_gvl(void *data) {
    struct scan_args *a = (struct scan_args *)data;
    a->envelope = cbm_central_scan(a->p, a->name, a->services_json, a->timeout_ms);
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
        NULL
    };
    rb_thread_call_without_gvl(scan_no_gvl, &a, RUBY_UBF_IO, NULL);
    VALUE data = parse_envelope_freed(a.envelope);
    return NIL_P(data) ? rb_ary_new() : data;
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
    char *envelope;
};

static void *connect_no_gvl(void *data) {
    struct connect_args *a = (struct connect_args *)data;
    a->envelope = cbm_central_connect(a->p, a->id, a->timeout_ms);
    return NULL;
}

static VALUE rb_central_connect(VALUE self, VALUE id_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct connect_args a = { p, StringValueCStr(id_v), (int32_t)NUM2INT(timeout_ms_v), NULL };
    rb_thread_call_without_gvl(connect_no_gvl, &a, RUBY_UBF_IO, NULL);
    (void)parse_envelope_freed(a.envelope);
    return Qtrue;
}

static VALUE rb_central_disconnect(VALUE self, VALUE id_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    char *env = cbm_central_disconnect(p, StringValueCStr(id_v));
    (void)parse_envelope_freed(env);
    return Qtrue;
}

static VALUE rb_peripheral_state(VALUE self, VALUE id_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    char *r = cbm_peripheral_state(p, StringValueCStr(id_v));
    // Intern directly from the malloc'd C string (from Swift `strdup`); avoid the
    // intermediate Ruby String. `rb_intern` copies into the symbol table, so it's
    // safe to free `r` afterwards.
    const char *state_cstr = r ? r : "unknown";
    VALUE sym = ID2SYM(rb_intern(state_cstr));
    if (r) free(r);
    return sym;
}

struct disco_svc_args {
    void *p; const char *id; const char *services_json; int32_t timeout_ms;
    char *envelope;
};

static void *disco_svc_no_gvl(void *data) {
    struct disco_svc_args *a = (struct disco_svc_args *)data;
    a->envelope = cbm_peripheral_discover_services(a->p, a->id, a->services_json, a->timeout_ms);
    return NULL;
}

// Ruby args: (identifier:String, services_json:String|nil, timeout_ms:Integer).
// `services_json` is a JSON-encoded array of UUID strings; nil = discover all.
static VALUE rb_peripheral_discover_services(VALUE self, VALUE id_v, VALUE services_json_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct disco_svc_args a = {
        p,
        StringValueCStr(id_v),
        NIL_P(services_json_v) ? NULL : StringValueCStr(services_json_v),
        (int32_t)NUM2INT(timeout_ms_v),
        NULL
    };
    rb_thread_call_without_gvl(disco_svc_no_gvl, &a, RUBY_UBF_IO, NULL);
    VALUE data = parse_envelope_freed(a.envelope);
    return NIL_P(data) ? rb_ary_new() : data;
}

struct disco_ch_args {
    void *p; const char *id; const char *svc_uuid; int32_t timeout_ms;
    char *envelope;
};

static void *disco_ch_no_gvl(void *data) {
    struct disco_ch_args *a = (struct disco_ch_args *)data;
    a->envelope = cbm_service_discover_characteristics(a->p, a->id, a->svc_uuid, a->timeout_ms);
    return NULL;
}

static VALUE rb_service_discover_characteristics(VALUE self, VALUE id_v, VALUE svc_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct disco_ch_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v),
        (int32_t)NUM2INT(timeout_ms_v), NULL
    };
    rb_thread_call_without_gvl(disco_ch_no_gvl, &a, RUBY_UBF_IO, NULL);
    VALUE data = parse_envelope_freed(a.envelope);
    return NIL_P(data) ? rb_ary_new() : data;
}

struct disco_included_svc_args {
    void *p; const char *id; const char *svc_uuid; int32_t timeout_ms;
    char *envelope;
};

static void *disco_included_svc_no_gvl(void *data) {
    struct disco_included_svc_args *a = (struct disco_included_svc_args *)data;
    a->envelope = cbm_service_discover_included_services(a->p, a->id, a->svc_uuid, a->timeout_ms);
    return NULL;
}

static VALUE rb_service_discover_included_services(VALUE self, VALUE id_v, VALUE svc_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct disco_included_svc_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v),
        (int32_t)NUM2INT(timeout_ms_v), NULL
    };
    rb_thread_call_without_gvl(disco_included_svc_no_gvl, &a, RUBY_UBF_IO, NULL);
    VALUE data = parse_envelope_freed(a.envelope);
    return NIL_P(data) ? rb_ary_new() : data;
}

struct read_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; int32_t len; char *envelope;
    unsigned char *buf;
};

static void *read_no_gvl(void *data) {
    struct read_args *a = (struct read_args *)data;
    a->buf = cbm_characteristic_read(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->len, &a->envelope);
    return NULL;
}

static VALUE rb_characteristic_read(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct read_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), 0, NULL, NULL
    };
    rb_thread_call_without_gvl(read_no_gvl, &a, RUBY_UBF_IO, NULL);
    // Swift contract: success → buf != NULL, envelope = ok-envelope;
    //                  failure → buf == NULL, envelope = err-envelope.
    // Parse the envelope first; on raise it frees buf via rb_protect.
    if (!a.envelope) {
        if (a.buf) free(a.buf);
        rb_raise(eErrorClass, "internal: read returned no envelope");
    }
    if (!a.buf) {
        // Error path. parse_envelope_freed will raise; nothing to free for buf.
        (void)parse_envelope_freed(a.envelope);
        // unreachable
        return Qnil;
    }
    // Success path. Free envelope (we don't need its nil data) and return buf.
    free(a.envelope);
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
    char *envelope;
};

static void *write_no_gvl(void *data) {
    struct write_args *a = (struct write_args *)data;
    a->envelope = cbm_characteristic_write(a->p, a->id, a->svc, a->ch,
                                           a->buf, a->buf_len, a->with_response, a->timeout_ms);
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
        NULL
    };
    rb_thread_call_without_gvl(write_no_gvl, &a, RUBY_UBF_IO, NULL);
    (void)parse_envelope_freed(a.envelope);
    return Qnil;
}

static VALUE rb_peripheral_last_disconnect_error(VALUE self, VALUE id_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    char *env = cbm_peripheral_last_disconnect_error(p, StringValueCStr(id_v));
    // Returns ok-envelope with data=null (clean disconnect) or data={error fields}.
    return parse_envelope_freed(env);
}

struct subscribe_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; char *envelope;
};

static void *subscribe_no_gvl(void *data) {
    struct subscribe_args *a = (struct subscribe_args *)data;
    a->envelope = cbm_characteristic_subscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms);
    return NULL;
}

static VALUE rb_characteristic_subscribe(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct subscribe_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), NULL
    };
    rb_thread_call_without_gvl(subscribe_no_gvl, &a, RUBY_UBF_IO, NULL);
    VALUE id = parse_envelope_freed(a.envelope);
    // Data payload is the integer subscription id.
    return id;
}

struct unsubscribe_args {
    void *p; const char *id; const char *svc; const char *ch;
    int32_t timeout_ms; char *envelope;
};

static void *unsubscribe_no_gvl(void *data) {
    struct unsubscribe_args *a = (struct unsubscribe_args *)data;
    a->envelope = cbm_characteristic_unsubscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms);
    return NULL;
}

static VALUE rb_characteristic_unsubscribe(VALUE self, VALUE id_v, VALUE svc_v, VALUE ch_v, VALUE timeout_ms_v) {
    void *p = DATA_PTR(self);
    if (!p) rb_raise(eErrorClass, "central is closed");
    Check_Type(timeout_ms_v, T_FIXNUM);
    struct unsubscribe_args a = {
        p, StringValueCStr(id_v), StringValueCStr(svc_v), StringValueCStr(ch_v),
        (int32_t)NUM2INT(timeout_ms_v), NULL
    };
    rb_thread_call_without_gvl(unsubscribe_no_gvl, &a, RUBY_UBF_IO, NULL);
    (void)parse_envelope_freed(a.envelope);
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
    // Sentinel discipline:
    //   closed (and no pending data) → :closed symbol (drained terminal state)
    //   timeout (no data, not closed) → nil
    //   data available                → mutable binary String
    // Returning a symbol is cheaper than raising on the per-poll FFI hot path.
    // The Ruby `Subscription#next_value` wrapper translates :closed → false.
    if (!a.buf) {
        if (a.closed) return ID2SYM(rb_intern("closed"));
        return Qnil;
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
    rb_define_method(cNative, "peripheral_state",                rb_peripheral_state,                1);
    rb_define_method(cNative, "peripheral_last_disconnect_error", rb_peripheral_last_disconnect_error, 1);
    rb_define_method(cNative, "discover_services",        rb_peripheral_discover_services,       3);
    rb_define_method(cNative, "discover_characteristics",        rb_service_discover_characteristics,        3);
    rb_define_method(cNative, "discover_included_services",      rb_service_discover_included_services,      3);
    rb_define_method(cNative, "characteristic_read",      rb_characteristic_read,                4);
    rb_define_method(cNative, "characteristic_write",     rb_characteristic_write,               6);
    rb_define_method(cNative, "characteristic_subscribe",   rb_characteristic_subscribe,   4);
    rb_define_method(cNative, "characteristic_unsubscribe", rb_characteristic_unsubscribe, 4);

    rb_define_module_function(mod, "__subscription_next_value", rb_subscription_next_value, 3);
    rb_define_module_function(mod, "__subscription_close",      rb_subscription_close,      2);
}
