#+build linux
// Trackpad gestures GLFW does not expose. raylib's GLFW is X11-only, so on
// Wayland we run under XWayland, which forwards touchpad pinches as XInput 2.4
// gesture events. GLFW drops those, so a second X connection selects them on
// the raylib window and is drained once per frame.
package platform

import "core:c"
import rl "vendor:raylib"

foreign import x11 "system:X11"
foreign import xi "system:Xi"

@(private) Display :: struct {}
@(private) Window :: c.ulong

@(private)
XGenericEventCookie :: struct {
	type:       c.int,
	serial:     c.ulong,
	send_event: b32,
	display:    ^Display,
	extension:  c.int,
	evtype:     c.int,
	cookie:     u32,
	data:       rawptr,
}

@(private)
XEvent :: struct #raw_union {
	type:   c.int,
	cookie: XGenericEventCookie,
	pad:    [24]c.long,
}

@(private)
XIEventMask :: struct {
	deviceid: c.int,
	mask_len: c.int,
	mask:     [^]u8,
}

// Leading fields of XIGesturePinchEvent (X11/extensions/XInput2.h).
@(private)
XIGesturePinchEvent :: struct {
	type:            c.int,
	serial:          c.ulong,
	send_event:      b32,
	display:         ^Display,
	extension:       c.int,
	evtype:          c.int,
	time:            c.ulong,
	deviceid:        c.int,
	sourceid:        c.int,
	detail:          c.int,
	root:            Window,
	event:           Window,
	child:           Window,
	root_x, root_y:  f64,
	event_x:         f64,
	event_y:         f64,
	delta_x:         f64,
	delta_y:         f64,
	delta_unaccel_x: f64,
	delta_unaccel_y: f64,
	scale:           f64,
	delta_angle:     f64,
	flags:           c.int,
}

@(private) GENERIC_EVENT :: 35
@(private) XI_ALL_MASTER_DEVICES :: 1
@(private) XI_GESTURE_PINCH_BEGIN :: 27
@(private) XI_GESTURE_PINCH_UPDATE :: 28
@(private) XI_GESTURE_PINCH_END :: 29

@(private, default_calling_convention = "c")
foreign x11 {
	XOpenDisplay :: proc(name: cstring) -> ^Display ---
	XCloseDisplay :: proc(d: ^Display) -> c.int ---
	XQueryExtension :: proc(d: ^Display, name: cstring, opcode, event, error: ^c.int) -> b32 ---
	XPending :: proc(d: ^Display) -> c.int ---
	XNextEvent :: proc(d: ^Display, e: ^XEvent) -> c.int ---
	XGetEventData :: proc(d: ^Display, cookie: ^XGenericEventCookie) -> b32 ---
	XFreeEventData :: proc(d: ^Display, cookie: ^XGenericEventCookie) ---
	XFlush :: proc(d: ^Display) -> c.int ---
}

@(private, default_calling_convention = "c")
foreign xi {
	XIQueryVersion :: proc(d: ^Display, major, minor: ^c.int) -> c.int ---
	XISelectEvents :: proc(d: ^Display, w: Window, masks: [^]XIEventMask, n: c.int) -> c.int ---
}

@(private) pinch_accum: f32
@(private) installed: bool
@(private) dpy: ^Display
@(private) xi_opcode: c.int
@(private) last_scale: f64 = 1

// Call after InitWindow.
install_gestures :: proc() {
	if installed {return}
	installed = true
	h := cast(^Window)rl.GetWindowHandle()
	if h == nil || h^ == 0 {return}
	d := XOpenDisplay(nil)
	if d == nil {return}
	ev, err: c.int
	major, minor: c.int = 2, 4
	if !XQueryExtension(d, "XInputExtension", &xi_opcode, &ev, &err) ||
	   XIQueryVersion(d, &major, &minor) != 0 || major < 2 || (major == 2 && minor < 4) {
		XCloseDisplay(d)
		return
	}
	bits: [4]u8
	for t in ([]int{XI_GESTURE_PINCH_BEGIN, XI_GESTURE_PINCH_UPDATE, XI_GESTURE_PINCH_END}) {
		bits[t >> 3] |= 1 << uint(t & 7)
	}
	mask := XIEventMask{XI_ALL_MASTER_DEVICES, len(bits), &bits[0]}
	XISelectEvents(d, h^, &mask, 1)
	XFlush(d)
	dpy = d
}

@(private)
drain :: proc() {
	if dpy == nil {return}
	for XPending(dpy) > 0 {
		e: XEvent
		XNextEvent(dpy, &e)
		if e.type != GENERIC_EVENT || e.cookie.extension != xi_opcode {continue}
		if !XGetEventData(dpy, &e.cookie) {continue}
		p := cast(^XIGesturePinchEvent)e.cookie.data
		switch e.cookie.evtype {
		case XI_GESTURE_PINCH_BEGIN:
			last_scale = p.scale
		case XI_GESTURE_PINCH_UPDATE, XI_GESTURE_PINCH_END:
			// scale is cumulative since begin; report the change like macOS magnification
			pinch_accum += f32(p.scale - last_scale)
			last_scale = p.scale
		}
		XFreeEventData(dpy, &e.cookie)
	}
}

// Pinch amount since the last call (+ = fingers apart = zoom in).
take_pinch :: proc() -> f32 {
	drain()
	v := pinch_accum
	pinch_accum = 0
	return v
}

// For automated tests.
inject_pinch :: proc(v: f32) {pinch_accum += v}

has_pinch :: proc() -> bool {return true}

// True when the XInput 2.4 gesture connection is open.
gestures_ready :: proc() -> bool {return dpy != nil}
