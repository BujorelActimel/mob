#+build darwin
// Native file chooser (NSOpenPanel).
package platform

import "core:strings"

has_file_chooser :: proc() -> bool {return objc_load()}

// Shows a modal open panel limited to files with extension ext, starting in
// start_dir. Blocks until the user picks a file (ok = true) or cancels.
choose_file :: proc(start_dir, ext: string, allocator := context.temp_allocator) -> (path: string, ok: bool) {
	if !objc_load() {return}
	pool := pool_push()
	defer pool_pop(pool)

	send := cast(proc "c" (rawptr, rawptr) -> rawptr)msg_send
	send_ptr := cast(proc "c" (rawptr, rawptr, rawptr) -> rawptr)msg_send
	send_bool := cast(proc "c" (rawptr, rawptr, bool))msg_send
	send_long := cast(proc "c" (rawptr, rawptr) -> int)msg_send
	ns_string :: proc(s: string) -> rawptr {
		from_utf8 := cast(proc "c" (rawptr, rawptr, cstring) -> rawptr)msg_send
		return from_utf8(objc_class("NSString"), objc_sel("stringWithUTF8String:"), strings.clone_to_cstring(s, context.temp_allocator))
	}

	panel := send(objc_class("NSOpenPanel"), objc_sel("openPanel"))
	if panel == nil {return}
	send_bool(panel, objc_sel("setCanChooseFiles:"), true)
	send_bool(panel, objc_sel("setCanChooseDirectories:"), false)
	send_bool(panel, objc_sel("setAllowsMultipleSelection:"), false)
	types := send_ptr(objc_class("NSArray"), objc_sel("arrayWithObject:"), ns_string(ext))
	send_ptr(panel, objc_sel("setAllowedFileTypes:"), types)
	if start_dir != "" {
		url := send_ptr(objc_class("NSURL"), objc_sel("fileURLWithPath:"), ns_string(start_dir))
		send_ptr(panel, objc_sel("setDirectoryURL:"), url)
	}
	NS_MODAL_RESPONSE_OK :: 1
	if send_long(panel, objc_sel("runModal")) != NS_MODAL_RESPONSE_OK {return}
	url := send(panel, objc_sel("URL"))
	if url == nil {return}
	utf8 := cast(proc "c" (rawptr, rawptr) -> cstring)msg_send
	cs := utf8(send(url, objc_sel("path")), objc_sel("UTF8String"))
	if cs == nil {return}
	return strings.clone(string(cs), allocator), true
}
