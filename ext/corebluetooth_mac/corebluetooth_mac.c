#include <ruby.h>
#include <ruby/thread.h>
#include "CoreBluetoothMac-Swift.h"

static VALUE eErrorClass;

struct call {
    void *(*fn)(void *);
    void *cancel;
    char *envelope;
    unsigned char *buf;
    int32_t len;
};

static void cancel_call(void *cancel) {
    corebluetooth_mac_cancel(cancel);
}

static VALUE call_body(VALUE data) {
    struct call *call = (struct call *)data;
    rb_thread_call_without_gvl(call->fn, call, cancel_call, call->cancel);
    return Qnil;
}

static void call_without_gvl(struct call *call) {
    int state = 0;
    call->cancel = corebluetooth_mac_cancel_new();
    rb_protect(call_body, (VALUE)call, &state);
    corebluetooth_mac_cancel_free(call->cancel);
    if (state) {
        corebluetooth_mac_free(call->envelope);
        corebluetooth_mac_free(call->buf);
        rb_jump_tag(state);
    }
}

static VALUE intern_or_nil(VALUE str) {
    return NIL_P(str) ? Qnil : rb_str_intern(str);
}

static VALUE parse_envelope(char *json) {
    VALUE str = rb_utf8_str_new_cstr(json);
    corebluetooth_mac_free(json);
    VALUE parsed = rb_funcall(rb_const_get(rb_cObject, rb_intern("JSON")), rb_intern("parse"), 1, str);
    if (RTEST(rb_hash_aref(parsed, rb_str_new_cstr("ok")))) {
        return rb_hash_aref(parsed, rb_str_new_cstr("data"));
    }
    VALUE error = rb_hash_aref(parsed, rb_str_new_cstr("error"));
    VALUE kwargs = rb_hash_new();
    rb_hash_aset(kwargs, ID2SYM(rb_intern("domain")), intern_or_nil(rb_hash_aref(error, rb_str_new_cstr("domain"))));
    rb_hash_aset(kwargs, ID2SYM(rb_intern("code")), rb_hash_aref(error, rb_str_new_cstr("code")));
    rb_hash_aset(kwargs, ID2SYM(rb_intern("code_name")), intern_or_nil(rb_hash_aref(error, rb_str_new_cstr("code_name"))));
    VALUE args[2] = { rb_hash_aref(error, rb_str_new_cstr("message")), kwargs };
    rb_exc_raise(rb_class_new_instance_kw(2, args, eErrorClass, RB_PASS_KEYWORDS));
}

static VALUE take_bytes(struct call *call) {
    if (!call->buf) return parse_envelope(call->envelope);
    corebluetooth_mac_free(call->envelope);
    VALUE str = rb_str_new((const char *)call->buf, call->len);
    corebluetooth_mac_free(call->buf);
    return str;
}

static VALUE array_or_empty(VALUE data) {
    return NIL_P(data) ? rb_ary_new() : data;
}

static const char *cstr_or_null(VALUE str) {
    return NIL_P(str) ? NULL : StringValueCStr(str);
}

static void central_free(void *p) {
    if (p) corebluetooth_mac_central_free(p);
}

static const rb_data_type_t central_type = {
    "CoreBluetoothMac::Native",
    { NULL, central_free, NULL, },
    NULL, NULL, RUBY_TYPED_FREE_IMMEDIATELY,
};

static VALUE rb_native_alloc(VALUE klass) {
    return TypedData_Wrap_Struct(klass, &central_type, NULL);
}

struct await_args { struct call call; void *p; int32_t timeout_ms; };

static void *await_no_gvl(void *data) {
    struct await_args *a = data;
    a->call.envelope = corebluetooth_mac_central_await_powered_on(a->p, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_initialize(VALUE self, VALUE timeout_ms) {
    DATA_PTR(self) = corebluetooth_mac_central_new();
    struct await_args a = { { await_no_gvl }, DATA_PTR(self), NUM2INT(timeout_ms) };
    call_without_gvl(&a.call);
    parse_envelope(a.call.envelope);
    return self;
}

static VALUE rb_native_central_id(VALUE self) {
    return LL2NUM(corebluetooth_mac_central_id(DATA_PTR(self)));
}

static VALUE rb_native_close(VALUE self) {
    corebluetooth_mac_central_close(DATA_PTR(self));
    return Qnil;
}

struct scan_args { struct call call; void *p; const char *name; const char *services_json; int32_t timeout_ms; };

static void *scan_no_gvl(void *data) {
    struct scan_args *a = data;
    a->call.envelope = corebluetooth_mac_central_scan(a->p, a->name, a->services_json, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_scan(VALUE self, VALUE name, VALUE services_json, VALUE timeout_ms) {
    struct scan_args a = { { scan_no_gvl }, DATA_PTR(self), cstr_or_null(name), cstr_or_null(services_json), NUM2INT(timeout_ms) };
    call_without_gvl(&a.call);
    return array_or_empty(parse_envelope(a.call.envelope));
}

static VALUE rb_cbm_hello(VALUE self) {
    char *hello = corebluetooth_mac_hello();
    VALUE str = rb_utf8_str_new_cstr(hello);
    corebluetooth_mac_free(hello);
    return str;
}

struct peripheral_args { struct call call; void *p; const char *id; int32_t timeout_ms; };

static void *connect_no_gvl(void *data) {
    struct peripheral_args *a = data;
    a->call.envelope = corebluetooth_mac_central_connect(a->p, a->id, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_connect(VALUE self, VALUE id, VALUE timeout_ms) {
    struct peripheral_args a = { { connect_no_gvl }, DATA_PTR(self), StringValueCStr(id), NUM2INT(timeout_ms) };
    call_without_gvl(&a.call);
    parse_envelope(a.call.envelope);
    return Qtrue;
}

static VALUE rb_native_disconnect(VALUE self, VALUE id) {
    parse_envelope(corebluetooth_mac_central_disconnect(DATA_PTR(self), StringValueCStr(id)));
    return Qtrue;
}

static VALUE rb_native_peripheral_state(VALUE self, VALUE id) {
    char *state = corebluetooth_mac_peripheral_state(DATA_PTR(self), StringValueCStr(id));
    VALUE sym = ID2SYM(rb_intern(state));
    corebluetooth_mac_free(state);
    return sym;
}

struct discover_services_args { struct call call; void *p; const char *id; const char *services_json; int32_t timeout_ms; };

static void *discover_services_no_gvl(void *data) {
    struct discover_services_args *a = data;
    a->call.envelope = corebluetooth_mac_peripheral_discover_services(a->p, a->id, a->services_json, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_discover_services(VALUE self, VALUE id, VALUE services_json, VALUE timeout_ms) {
    struct discover_services_args a = {
        { discover_services_no_gvl }, DATA_PTR(self), StringValueCStr(id), cstr_or_null(services_json), NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    return array_or_empty(parse_envelope(a.call.envelope));
}

struct service_args { struct call call; void *p; const char *id; const char *svc; int32_t timeout_ms; };

static void *discover_characteristics_no_gvl(void *data) {
    struct service_args *a = data;
    a->call.envelope = corebluetooth_mac_service_discover_characteristics(a->p, a->id, a->svc, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_discover_characteristics(VALUE self, VALUE id, VALUE svc, VALUE timeout_ms) {
    struct service_args a = { { discover_characteristics_no_gvl }, DATA_PTR(self), StringValueCStr(id), StringValueCStr(svc), NUM2INT(timeout_ms) };
    call_without_gvl(&a.call);
    return array_or_empty(parse_envelope(a.call.envelope));
}

static void *discover_included_services_no_gvl(void *data) {
    struct service_args *a = data;
    a->call.envelope = corebluetooth_mac_service_discover_included_services(a->p, a->id, a->svc, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_discover_included_services(VALUE self, VALUE id, VALUE svc, VALUE timeout_ms) {
    struct service_args a = { { discover_included_services_no_gvl }, DATA_PTR(self), StringValueCStr(id), StringValueCStr(svc), NUM2INT(timeout_ms) };
    call_without_gvl(&a.call);
    return array_or_empty(parse_envelope(a.call.envelope));
}

struct characteristic_args {
    struct call call; void *p; const char *id; const char *svc; const char *ch;
    const unsigned char *data; int32_t data_len; int32_t with_response; int32_t timeout_ms;
};

static void *characteristic_read_no_gvl(void *data) {
    struct characteristic_args *a = data;
    a->call.buf = corebluetooth_mac_characteristic_read(a->p, a->id, a->svc, a->ch, a->timeout_ms, &a->call.len, &a->call.envelope, a->call.cancel);
    return NULL;
}

static VALUE rb_native_characteristic_read(VALUE self, VALUE id, VALUE svc, VALUE ch, VALUE timeout_ms) {
    struct characteristic_args a = {
        .call = { characteristic_read_no_gvl }, .p = DATA_PTR(self),
        .id = StringValueCStr(id), .svc = StringValueCStr(svc), .ch = StringValueCStr(ch), .timeout_ms = NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    return take_bytes(&a.call);
}

static void *characteristic_write_no_gvl(void *data) {
    struct characteristic_args *a = data;
    a->call.envelope = corebluetooth_mac_characteristic_write(a->p, a->id, a->svc, a->ch, a->data, a->data_len, a->with_response, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_characteristic_write(VALUE self, VALUE id, VALUE svc, VALUE ch, VALUE data, VALUE with_response, VALUE timeout_ms) {
    StringValue(data);
    struct characteristic_args a = {
        .call = { characteristic_write_no_gvl }, .p = DATA_PTR(self),
        .id = StringValueCStr(id), .svc = StringValueCStr(svc), .ch = StringValueCStr(ch),
        .data = (const unsigned char *)RSTRING_PTR(data), .data_len = (int32_t)RSTRING_LEN(data),
        .with_response = NUM2INT(with_response), .timeout_ms = NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    parse_envelope(a.call.envelope);
    return Qnil;
}

static void *read_rssi_no_gvl(void *data) {
    struct peripheral_args *a = data;
    a->call.envelope = corebluetooth_mac_peripheral_read_rssi(a->p, a->id, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_peripheral_read_rssi(VALUE self, VALUE id, VALUE timeout_ms) {
    struct peripheral_args a = { { read_rssi_no_gvl }, DATA_PTR(self), StringValueCStr(id), NUM2INT(timeout_ms) };
    call_without_gvl(&a.call);
    return parse_envelope(a.call.envelope);
}

static VALUE rb_native_peripheral_max_write_length(VALUE self, VALUE id, VALUE with_response) {
    return parse_envelope(corebluetooth_mac_peripheral_max_write_length(DATA_PTR(self), StringValueCStr(id), NUM2INT(with_response)));
}

static VALUE rb_native_peripheral_last_disconnect_error(VALUE self, VALUE id) {
    return parse_envelope(corebluetooth_mac_peripheral_last_disconnect_error(DATA_PTR(self), StringValueCStr(id)));
}

static void *poll_events_no_gvl(void *data) {
    struct peripheral_args *a = data;
    a->call.envelope = corebluetooth_mac_peripheral_poll_events(a->p, a->id, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_peripheral_poll_events(VALUE self, VALUE id, VALUE timeout_ms) {
    struct peripheral_args a = { { poll_events_no_gvl }, DATA_PTR(self), StringValueCStr(id), NUM2INT(timeout_ms) };
    call_without_gvl(&a.call);
    return parse_envelope(a.call.envelope);
}

static void *subscribe_no_gvl(void *data) {
    struct characteristic_args *a = data;
    a->call.envelope = corebluetooth_mac_characteristic_subscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_characteristic_subscribe(VALUE self, VALUE id, VALUE svc, VALUE ch, VALUE timeout_ms) {
    struct characteristic_args a = {
        .call = { subscribe_no_gvl }, .p = DATA_PTR(self),
        .id = StringValueCStr(id), .svc = StringValueCStr(svc), .ch = StringValueCStr(ch), .timeout_ms = NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    return parse_envelope(a.call.envelope);
}

static void *unsubscribe_no_gvl(void *data) {
    struct characteristic_args *a = data;
    a->call.envelope = corebluetooth_mac_characteristic_unsubscribe(a->p, a->id, a->svc, a->ch, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_characteristic_unsubscribe(VALUE self, VALUE id, VALUE svc, VALUE ch, VALUE timeout_ms) {
    struct characteristic_args a = {
        .call = { unsubscribe_no_gvl }, .p = DATA_PTR(self),
        .id = StringValueCStr(id), .svc = StringValueCStr(svc), .ch = StringValueCStr(ch), .timeout_ms = NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    parse_envelope(a.call.envelope);
    return Qnil;
}

struct next_args { struct call call; int64_t sub_id; int32_t timeout_ms; int32_t closed; };

static void *next_no_gvl(void *data) {
    struct next_args *a = data;
    a->call.buf = corebluetooth_mac_subscription_next_value(a->sub_id, a->timeout_ms, &a->closed, &a->call.len, a->call.cancel);
    return NULL;
}

static VALUE rb_subscription_next_value(VALUE self, VALUE central_id, VALUE sub_id, VALUE timeout_ms) {
    struct next_args a = { { next_no_gvl }, NUM2LL(sub_id), NUM2INT(timeout_ms), 0 };
    call_without_gvl(&a.call);
    if (!a.call.buf) return a.closed ? ID2SYM(rb_intern("closed")) : Qnil;
    VALUE str = rb_str_new((const char *)a.call.buf, a.call.len);
    corebluetooth_mac_free(a.call.buf);
    return str;
}

static VALUE rb_subscription_close(VALUE self, VALUE central_id, VALUE sub_id) {
    corebluetooth_mac_subscription_close(NUM2LL(sub_id));
    return Qnil;
}

static void *discover_descriptors_no_gvl(void *data) {
    struct characteristic_args *a = data;
    a->call.envelope = corebluetooth_mac_characteristic_discover_descriptors(a->p, a->id, a->svc, a->ch, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_characteristic_discover_descriptors(VALUE self, VALUE id, VALUE svc, VALUE ch, VALUE timeout_ms) {
    struct characteristic_args a = {
        .call = { discover_descriptors_no_gvl }, .p = DATA_PTR(self),
        .id = StringValueCStr(id), .svc = StringValueCStr(svc), .ch = StringValueCStr(ch), .timeout_ms = NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    return array_or_empty(parse_envelope(a.call.envelope));
}

struct descriptor_args {
    struct call call; void *p; const char *id; const char *svc; const char *ch; const char *desc;
    const unsigned char *data; int32_t data_len; int32_t timeout_ms;
};

static void *descriptor_read_no_gvl(void *data) {
    struct descriptor_args *a = data;
    a->call.buf = corebluetooth_mac_descriptor_read(a->p, a->id, a->svc, a->ch, a->desc, a->timeout_ms, &a->call.len, &a->call.envelope, a->call.cancel);
    return NULL;
}

static VALUE rb_native_descriptor_read(VALUE self, VALUE id, VALUE svc, VALUE ch, VALUE desc, VALUE timeout_ms) {
    struct descriptor_args a = {
        .call = { descriptor_read_no_gvl }, .p = DATA_PTR(self),
        .id = StringValueCStr(id), .svc = StringValueCStr(svc), .ch = StringValueCStr(ch), .desc = StringValueCStr(desc),
        .timeout_ms = NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    return take_bytes(&a.call);
}

static void *descriptor_write_no_gvl(void *data) {
    struct descriptor_args *a = data;
    a->call.envelope = corebluetooth_mac_descriptor_write(a->p, a->id, a->svc, a->ch, a->desc, a->data, a->data_len, a->timeout_ms, a->call.cancel);
    return NULL;
}

static VALUE rb_native_descriptor_write(VALUE self, VALUE id, VALUE svc, VALUE ch, VALUE desc, VALUE data, VALUE timeout_ms) {
    StringValue(data);
    struct descriptor_args a = {
        .call = { descriptor_write_no_gvl }, .p = DATA_PTR(self),
        .id = StringValueCStr(id), .svc = StringValueCStr(svc), .ch = StringValueCStr(ch), .desc = StringValueCStr(desc),
        .data = (const unsigned char *)RSTRING_PTR(data), .data_len = (int32_t)RSTRING_LEN(data), .timeout_ms = NUM2INT(timeout_ms)
    };
    call_without_gvl(&a.call);
    parse_envelope(a.call.envelope);
    return Qtrue;
}

void Init_corebluetooth_mac(void) {
    VALUE mod = rb_define_module("CoreBluetoothMac");
    eErrorClass = rb_const_get(mod, rb_intern("Error"));
    rb_global_variable(&eErrorClass);

    rb_define_singleton_method(mod, "__hello", rb_cbm_hello, 0);

    VALUE native = rb_define_class_under(mod, "Native", rb_cObject);
    rb_define_alloc_func(native, rb_native_alloc);
    rb_define_method(native, "initialize", rb_native_initialize, 1);
    rb_define_method(native, "central_id", rb_native_central_id, 0);
    rb_define_method(native, "close", rb_native_close, 0);
    rb_define_method(native, "scan", rb_native_scan, 3);
    rb_define_method(native, "connect", rb_native_connect, 2);
    rb_define_method(native, "disconnect", rb_native_disconnect, 1);
    rb_define_method(native, "peripheral_state", rb_native_peripheral_state, 1);
    rb_define_method(native, "peripheral_last_disconnect_error", rb_native_peripheral_last_disconnect_error, 1);
    rb_define_method(native, "peripheral_poll_events", rb_native_peripheral_poll_events, 2);
    rb_define_method(native, "peripheral_read_rssi", rb_native_peripheral_read_rssi, 2);
    rb_define_method(native, "peripheral_max_write_length", rb_native_peripheral_max_write_length, 2);
    rb_define_method(native, "discover_services", rb_native_discover_services, 3);
    rb_define_method(native, "discover_characteristics", rb_native_discover_characteristics, 3);
    rb_define_method(native, "discover_included_services", rb_native_discover_included_services, 3);
    rb_define_method(native, "characteristic_read", rb_native_characteristic_read, 4);
    rb_define_method(native, "characteristic_write", rb_native_characteristic_write, 6);
    rb_define_method(native, "characteristic_subscribe", rb_native_characteristic_subscribe, 4);
    rb_define_method(native, "characteristic_unsubscribe", rb_native_characteristic_unsubscribe, 4);
    rb_define_method(native, "characteristic_discover_descriptors", rb_native_characteristic_discover_descriptors, 4);
    rb_define_method(native, "descriptor_read", rb_native_descriptor_read, 5);
    rb_define_method(native, "descriptor_write", rb_native_descriptor_write, 6);

    rb_ext_ractor_safe(true);
    rb_define_module_function(mod, "__subscription_next_value", rb_subscription_next_value, 3);
    rb_define_module_function(mod, "__subscription_close", rb_subscription_close, 2);
}
