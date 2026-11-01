#+build !darwin
package platform

has_file_chooser :: proc() -> bool {return false}

choose_file :: proc(start_dir, ext: string, allocator := context.temp_allocator) -> (path: string, ok: bool) {return}
