#+build !darwin
#+build !linux
package platform

@(private)
pinch_accum: f32

install_gestures :: proc() {}

take_pinch :: proc() -> f32 {
	v := pinch_accum
	pinch_accum = 0
	return v
}

inject_pinch :: proc(v: f32) {pinch_accum += v}

has_pinch :: proc() -> bool {return false}

gestures_ready :: proc() -> bool {return false}
