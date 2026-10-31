#+build darwin
// Trackpad gestures GLFW does not expose. On macOS a local NSEvent monitor
// sees magnify (pinch) events before GLFW processes them. The Objective-C
// runtime is called through objc_msgSend directly.
package platform

import "core:c"
import "core:dynlib"

@(private)
Block_Descriptor :: struct {
	reserved: c.ulong,
	size:     c.ulong,
}

@(private)
Block_Literal :: struct {
	isa:        rawptr,
	flags:      i32,
	reserved:   i32,
	invoke:     proc "c" (block: rawptr, event: rawptr) -> rawptr,
	descriptor: ^Block_Descriptor,
}

@(private) pinch_accum: f32
@(private) msg_send: rawptr // objc_msgSend, cast per call signature
@(private) descriptor := Block_Descriptor{0, size_of(Block_Literal)}
@(private) block: Block_Literal
@(private) installed: bool
@(private) sel_type: rawptr
@(private) sel_magnification: rawptr

NS_EVENT_TYPE_MAGNIFY :: 30

@(private)
on_event :: proc "c" (b: rawptr, event: rawptr) -> rawptr {
	send_uint := cast(proc "c" (rawptr, rawptr) -> c.ulong)msg_send
	if send_uint(event, sel_type) == NS_EVENT_TYPE_MAGNIFY {
		send_f64 := cast(proc "c" (rawptr, rawptr) -> f64)msg_send
		pinch_accum += f32(send_f64(event, sel_magnification))
	}
	return event // never swallow: GLFW still sees every event
}

install_gestures :: proc() {
	if installed {return}
	installed = true
	lib, ok := dynlib.load_library("/usr/lib/libobjc.A.dylib")
	if !ok {return}
	sys, sys_ok := dynlib.load_library("/usr/lib/libSystem.B.dylib")
	if !sys_ok {return}
	msg_send, _ = dynlib.symbol_address(lib, "objc_msgSend")
	get_class := cast(proc "c" (cstring) -> rawptr)(dynlib.symbol_address(lib, "objc_getClass") or_else nil)
	sel := cast(proc "c" (cstring) -> rawptr)(dynlib.symbol_address(lib, "sel_registerName") or_else nil)
	global_block, _ := dynlib.symbol_address(sys, "_NSConcreteGlobalBlock")
	if msg_send == nil || get_class == nil || sel == nil || global_block == nil {return}
	sel_type = sel("type")
	sel_magnification = sel("magnification")
	BLOCK_IS_GLOBAL :: 1 << 28
	block = {isa = global_block, flags = BLOCK_IS_GLOBAL, invoke = on_event, descriptor = &descriptor}
	MASK_MAGNIFY: c.ulonglong : 1 << NS_EVENT_TYPE_MAGNIFY
	add := cast(proc "c" (rawptr, rawptr, c.ulonglong, rawptr) -> rawptr)msg_send
	add(get_class("NSEvent"), sel("addLocalMonitorForEventsMatchingMask:handler:"), MASK_MAGNIFY, &block)
}

// Pinch amount since the last call (+ = fingers apart = zoom in).
take_pinch :: proc() -> f32 {
	v := pinch_accum
	pinch_accum = 0
	return v
}

// For automated tests.
inject_pinch :: proc(v: f32) {pinch_accum += v}

has_pinch :: proc() -> bool {return true}

// True when the native magnify monitor is registered.
gestures_ready :: proc() -> bool {return msg_send != nil && sel_magnification != nil}
