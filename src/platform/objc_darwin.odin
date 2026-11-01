#+build darwin
// Minimal Objective-C runtime access. Every message goes through
// objc_msgSend, cast to the signature of the call.
package platform

import "core:dynlib"

@(private) msg_send: rawptr
@(private) objc_class: proc "c" (name: cstring) -> rawptr
@(private) objc_sel: proc "c" (name: cstring) -> rawptr
@(private) pool_push: proc "c" () -> rawptr
@(private) pool_pop: proc "c" (pool: rawptr)
@(private) objc_tried: bool

@(private)
objc_load :: proc() -> bool {
	if !objc_tried {
		objc_tried = true
		if lib, ok := dynlib.load_library("/usr/lib/libobjc.A.dylib"); ok {
			msg_send, _ = dynlib.symbol_address(lib, "objc_msgSend")
			objc_class = cast(proc "c" (cstring) -> rawptr)(dynlib.symbol_address(lib, "objc_getClass") or_else nil)
			objc_sel = cast(proc "c" (cstring) -> rawptr)(dynlib.symbol_address(lib, "sel_registerName") or_else nil)
			pool_push = cast(proc "c" () -> rawptr)(dynlib.symbol_address(lib, "objc_autoreleasePoolPush") or_else nil)
			pool_pop = cast(proc "c" (rawptr))(dynlib.symbol_address(lib, "objc_autoreleasePoolPop") or_else nil)
		}
	}
	return msg_send != nil && objc_class != nil && objc_sel != nil && pool_push != nil && pool_pop != nil
}
