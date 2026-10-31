// Scene rendering: mesh cache, shadow + contact shadow passes, wood shading,
// ground grid, feature edges and the screen-space selection outline.
package render

import "core:hash"
import "core:math/linalg"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"
import "../geom"
import "../model"

Vec3 :: [3]f32
Mat4 :: linalg.Matrix4f32

SHADOW_SIZE :: 2048
CONTACT_SIZE :: 1024
CONTACT_FAR :: 420.0
SHADOW_SLOT :: 14
CONTACT_SLOT :: 15

LIGHT_DIR :: Vec3{0.42, -1.0, -0.55} // direction the light travels

Gpu_Mesh :: struct {
	mesh:   rl.Mesh,
	data:   geom.Mesh_Data, // kept for picking, edges and snapping
	lo, hi: Vec3,
	used:   bool,
}

Depth_Target :: struct {
	rt:       rl.RenderTexture2D,
	view_proj: Mat4,
	size:     i32,
}

Wood_Locs :: struct {
	light_vp, light_dir, view_pos, mat_kind, grain_rot, seed, tint, shadow_map, shadow_texel: i32,
}

Ground_Locs :: struct {
	light_vp, contact_map, contact_vp, contact_range, view_pos, ground_color, fade_color, fade_radius, scene_center, show_grid, shadow_map, shadow_texel: i32,
}

Renderer :: struct {
	cache:        map[u64]Gpu_Mesh,
	wood:         rl.Shader,
	wood_locs:    Wood_Locs,
	wood_mat:     rl.Material,
	depth:        rl.Shader,
	depth_mat:    rl.Material,
	flat:         rl.Shader,
	flat_mat:     rl.Material,
	ground:       rl.Shader,
	ground_locs:  Ground_Locs,
	outline:      rl.Shader,
	outline_locs: struct {
		texel, radius, sel_color, hover_color: i32,
	},
	shadow:       Depth_Target,
	contact:      Depth_Target,
	contact_range: [3]f32,
	mask:         rl.RenderTexture2D,
	mask_w, mask_h: i32,
	wall:         rl.Mesh,
	shadows_dirty: bool,
	scene_lo, scene_hi: Vec3,
	has_scene:    bool,
}

Part_Flag :: enum u8 {
	Selected,
	Hovered,
	Ghost, // drawn dimmed, e.g. while editing its outline
}
Part_Flags :: bit_set[Part_Flag;u8]

Frame :: struct {
	camera:      rl.Camera3D,
	near, far:   f32,
	flags:       []Part_Flags, // one per res.parts entry
	highlighted: bool, // any part selected or hovered
	show_edges:  bool,
	show_grid:   bool,
	show_room:   bool,
}

@(private)
load_depth_target :: proc(size: i32) -> Depth_Target {
	t: Depth_Target
	t.size = size
	t.rt.id = rlgl.LoadFramebuffer()
	rlgl.EnableFramebuffer(t.rt.id)
	// a colour attachment keeps the FBO complete on every driver
	t.rt.texture.id = rlgl.LoadTexture(nil, size, size, i32(rl.PixelFormat.UNCOMPRESSED_R8G8B8A8), 1)
	t.rt.texture.width = size
	t.rt.texture.height = size
	t.rt.texture.mipmaps = 1
	t.rt.texture.format = .UNCOMPRESSED_R8G8B8A8
	t.rt.depth.id = rlgl.LoadTextureDepth(size, size, false)
	t.rt.depth.width = size
	t.rt.depth.height = size
	t.rt.depth.format = rl.PixelFormat(19) // DEPTH_COMPONENT_24BIT
	t.rt.depth.mipmaps = 1
	rlgl.FramebufferAttach(t.rt.id, t.rt.texture.id, i32(rlgl.FramebufferAttachType.COLOR_CHANNEL0), i32(rlgl.FramebufferAttachTextureType.TEXTURE2D), 0)
	rlgl.FramebufferAttach(t.rt.id, t.rt.depth.id, i32(rlgl.FramebufferAttachType.DEPTH), i32(rlgl.FramebufferAttachTextureType.TEXTURE2D), 0)
	if !rlgl.FramebufferComplete(t.rt.id) {
		rl.TraceLog(.WARNING, "mob: shadow framebuffer incomplete")
	}
	rlgl.DisableFramebuffer()
	// linear filtering on the depth texture gives slightly softer PCF taps on some drivers
	rlgl.TextureParameters(t.rt.depth.id, rlgl.TEXTURE_WRAP_S, rlgl.TEXTURE_WRAP_CLAMP)
	rlgl.TextureParameters(t.rt.depth.id, rlgl.TEXTURE_WRAP_T, rlgl.TEXTURE_WRAP_CLAMP)
	return t
}

@(private)
unload_depth_target :: proc(t: ^Depth_Target) {
	rlgl.UnloadFramebuffer(t.rt.id)
	rlgl.UnloadTexture(t.rt.texture.id)
	rlgl.UnloadTexture(t.rt.depth.id)
}

init :: proc(r: ^Renderer) {
	r.cache = make(map[u64]Gpu_Mesh)
	r.wood = rl.LoadShaderFromMemory(WOOD_VS, WOOD_FS)
	loc :: proc(s: rl.Shader, name: cstring) -> i32 {return i32(rl.GetShaderLocation(s, name))}
	r.wood_locs = {
		light_vp     = loc(r.wood, "lightVP"),
		light_dir    = loc(r.wood, "lightDir"),
		view_pos     = loc(r.wood, "viewPos"),
		mat_kind     = loc(r.wood, "matKind"),
		grain_rot    = loc(r.wood, "grainRot"),
		seed         = loc(r.wood, "seed"),
		tint         = loc(r.wood, "tint"),
		shadow_map   = loc(r.wood, "shadowMap"),
		shadow_texel = loc(r.wood, "shadowTexel"),
	}
	r.wood_mat = rl.LoadMaterialDefault()
	r.wood_mat.shader = r.wood

	r.depth = rl.LoadShaderFromMemory(DEPTH_VS, DEPTH_FS)
	r.depth_mat = rl.LoadMaterialDefault()
	r.depth_mat.shader = r.depth

	r.flat = rl.LoadShaderFromMemory(DEPTH_VS, FLAT_FS)
	r.flat_mat = rl.LoadMaterialDefault()
	r.flat_mat.shader = r.flat

	r.ground = rl.LoadShaderFromMemory(GROUND_VS, GROUND_FS)
	r.ground_locs = {
		light_vp      = loc(r.ground, "lightVP"),
		contact_map   = loc(r.ground, "contactMap"),
		contact_vp    = loc(r.ground, "contactVP"),
		contact_range = loc(r.ground, "contactRange"),
		view_pos      = loc(r.ground, "viewPos"),
		ground_color  = loc(r.ground, "groundColor"),
		fade_color    = loc(r.ground, "fadeColor"),
		fade_radius   = loc(r.ground, "fadeRadius"),
		scene_center  = loc(r.ground, "sceneCenter"),
		show_grid     = loc(r.ground, "showGrid"),
		shadow_map    = loc(r.ground, "shadowMap"),
		shadow_texel  = loc(r.ground, "shadowTexel"),
	}

	r.outline = rl.LoadShaderFromMemory(nil, OUTLINE_FS)
	r.outline_locs = {
		texel       = loc(r.outline, "texel"),
		radius      = loc(r.outline, "radius"),
		sel_color   = loc(r.outline, "selColor"),
		hover_color = loc(r.outline, "hoverColor"),
	}

	r.shadow = load_depth_target(SHADOW_SIZE)
	r.contact = load_depth_target(CONTACT_SIZE)
	r.wall = rl.GenMeshCube(1, 1, 1)
	r.shadows_dirty = true

	slot_s: i32 = SHADOW_SLOT
	slot_c: i32 = CONTACT_SLOT
	texel := [2]f32{1.0 / SHADOW_SIZE, 1.0 / SHADOW_SIZE}
	rl.SetShaderValue(r.wood, r.wood_locs.shadow_map, &slot_s, .INT)
	rl.SetShaderValue(r.wood, r.wood_locs.shadow_texel, &texel, .VEC2)
	rl.SetShaderValue(r.ground, r.ground_locs.shadow_map, &slot_s, .INT)
	rl.SetShaderValue(r.ground, r.ground_locs.contact_map, &slot_c, .INT)
	rl.SetShaderValue(r.ground, r.ground_locs.shadow_texel, &texel, .VEC2)
}

shutdown :: proc(r: ^Renderer) {
	for _, &g in r.cache {free_gpu_mesh(&g)}
	delete(r.cache)
	unload_depth_target(&r.shadow)
	unload_depth_target(&r.contact)
	if r.mask.id != 0 {rl.UnloadRenderTexture(r.mask)}
	rl.UnloadMesh(r.wall)
	rl.UnloadShader(r.wood)
	rl.UnloadShader(r.depth)
	rl.UnloadShader(r.flat)
	rl.UnloadShader(r.ground)
	rl.UnloadShader(r.outline)
}

@(private)
free_gpu_mesh :: proc(g: ^Gpu_Mesh) {
	if g.mesh.vaoId != 0 {rl.UnloadMesh(g.mesh)}
	geom.mesh_destroy(&g.data)
}

// Builds meshes for new shapes and frees meshes no longer referenced.
sync :: proc(r: ^Renderer, res: ^model.Eval_Result) {
	for _, &g in r.cache {g.used = false}
	r.has_scene = false
	lo := Vec3{max(f32), max(f32), max(f32)}
	hi := -lo
	for &rp in res.parts {
		g, ok := &r.cache[rp.hash]
		if !ok {
			ng: Gpu_Mesh
			geom.mesh_init(&ng.data)
			model.build_mesh(rp, &ng.data)
			ng.lo, ng.hi = geom.mesh_bounds(ng.data)
			n := len(ng.data.positions)
			if n > 0 {
				ng.mesh.vertexCount = i32(n)
				ng.mesh.triangleCount = i32(n / 3)
				ng.mesh.vertices = cast([^]f32)raw_data(ng.data.positions)
				ng.mesh.normals = cast([^]f32)raw_data(ng.data.normals)
				ng.mesh.texcoords = cast([^]f32)raw_data(ng.data.uvs)
				rl.UploadMesh(&ng.mesh, false)
				// CPU arrays belong to us, not to raylib
				ng.mesh.vertices = nil
				ng.mesh.normals = nil
				ng.mesh.texcoords = nil
			}
			r.cache[rp.hash] = ng
			g = &r.cache[rp.hash]
		}
		g.used = true
		rp.world_lo, rp.world_hi = transform_aabb(rp.world, g.lo, g.hi)
		lo = linalg.min(lo, rp.world_lo)
		hi = linalg.max(hi, rp.world_hi)
		r.has_scene = true
	}
	stale := make([dynamic]u64, context.temp_allocator)
	for k, g in r.cache {if !g.used {append(&stale, k)}}
	for k in stale {
		free_gpu_mesh(&r.cache[k])
		delete_key(&r.cache, k)
	}
	if r.has_scene {
		r.scene_lo, r.scene_hi = lo, hi
	} else {
		r.scene_lo, r.scene_hi = {-500, 0, -500}, {500, 500, 500}
	}
	r.shadows_dirty = true
}

mesh_of :: proc(r: ^Renderer, rp: model.Resolved_Part) -> ^Gpu_Mesh {
	return &r.cache[rp.hash]
}

transform_aabb :: proc(m: Mat4, lo, hi: Vec3) -> (Vec3, Vec3) {
	olo := Vec3{max(f32), max(f32), max(f32)}
	ohi := -olo
	for i in 0 ..< 8 {
		p := Vec3{(i & 1) != 0 ? hi.x : lo.x, (i & 2) != 0 ? hi.y : lo.y, (i & 4) != 0 ? hi.z : lo.z}
		w := (m * [4]f32{p.x, p.y, p.z, 1}).xyz
		olo = linalg.min(olo, w)
		ohi = linalg.max(ohi, w)
	}
	return olo, ohi
}

part_world_bounds :: proc(r: ^Renderer, rp: model.Resolved_Part) -> (Vec3, Vec3) {
	return rp.world_lo, rp.world_hi
}

// ---------------------------------------------------------------------------
// Picking

Pick :: struct {
	hit:          bool,
	id:           model.Id,
	index:        int, // into res.parts
	t:            f32,
	point:        Vec3,
	normal:       Vec3, // world
	local_point:  Vec3,
	local_normal: Vec3,
}

pick :: proc(r: ^Renderer, res: ^model.Eval_Result, ray: geom.Ray, skip: []model.Id = nil) -> Pick {
	best := Pick{t = max(f32)}
	outer: for rp, i in res.parts {
		for s in skip {if s == rp.id {continue outer}}
		// cheap world-space reject before inverting the part's matrix
		if t, ok := geom.ray_aabb(ray, rp.world_lo - 0.01, rp.world_hi + 0.01); !ok || t > best.t {continue}
		g := mesh_of(r, rp)
		if g == nil || len(g.data.positions) == 0 {continue}
		inv := linalg.inverse(rp.world)
		lr := geom.Ray {
			origin = (inv * [4]f32{ray.origin.x, ray.origin.y, ray.origin.z, 1}).xyz,
			dir    = (inv * [4]f32{ray.dir.x, ray.dir.y, ray.dir.z, 0}).xyz,
		}
		if t, ok := geom.ray_aabb(lr, g.lo - 0.01, g.hi + 0.01); !ok || t > best.t {continue}
		t, tri, ok := geom.ray_mesh(lr, g.data.positions[:])
		if !ok || t >= best.t {continue}
		a := g.data.positions[tri * 3]
		b := g.data.positions[tri * 3 + 1]
		c := g.data.positions[tri * 3 + 2]
		ln := linalg.normalize(linalg.cross(b - a, c - a))
		nm := linalg.transpose(linalg.inverse(linalg.matrix3_from_matrix4(rp.world)))
		best = {
			hit          = true,
			id           = rp.id,
			index        = i,
			t            = t,
			point        = ray.origin + ray.dir * t,
			normal       = linalg.normalize(nm * ln),
			local_point  = lr.origin + lr.dir * t,
			local_normal = ln,
		}
	}
	return best
}

// ---------------------------------------------------------------------------
// Drawing

@(private)
scene_radius :: proc(r: ^Renderer) -> (Vec3, f32) {
	c := (r.scene_lo + r.scene_hi) * 0.5
	rad := max(linalg.length(r.scene_hi - r.scene_lo) * 0.5, 400)
	return c, rad
}

@(private)
color_of :: proc(c: [3]u8) -> rl.Color {return {c[0], c[1], c[2], 255}}

@(private)
seed_of :: proc(id: model.Id) -> f32 {
	x := id
	h := hash.fnv32a(([^]u8)(&x)[:4])
	return f32(h % 1000) / 1000
}

@(private)
draw_depth_pass :: proc(r: ^Renderer, res: ^model.Eval_Result, t: ^Depth_Target, cam: rl.Camera3D, near, far: f64) {
	rl.BeginTextureMode(t.rt)
	rl.ClearBackground(rl.WHITE)
	rlgl.SetClipPlanes(near, far)
	rl.BeginMode3D(cam)
	t.view_proj = Mat4(rlgl.GetMatrixProjection()) * Mat4(rlgl.GetMatrixModelview())
	rlgl.DisableBackfaceCulling()
	for rp in res.parts {
		g := mesh_of(r, rp)
		if g == nil || g.mesh.vaoId == 0 {continue}
		rl.DrawMesh(g.mesh, r.depth_mat, rl.Matrix(rp.world))
	}
	rlgl.EnableBackfaceCulling()
	rl.EndMode3D()
	rl.EndTextureMode()
}

update_shadows :: proc(r: ^Renderer, res: ^model.Eval_Result) {
	if !r.shadows_dirty {return}
	r.shadows_dirty = false
	c, rad := scene_radius(r)
	ld := linalg.normalize(LIGHT_DIR)
	light := rl.Camera3D {
		position   = c - ld * rad * 3,
		target     = c,
		up         = {0, 0, -1},
		fovy       = rad * 2.1,
		projection = .ORTHOGRAPHIC,
	}
	draw_depth_pass(r, res, &r.shadow, light, f64(rad), f64(rad * 5))

	ext := max(r.scene_hi.x - r.scene_lo.x, r.scene_hi.z - r.scene_lo.z) * 0.5 + 400
	below := rl.Camera3D {
		position   = {c.x, -10, c.z},
		target     = {c.x, 1000, c.z},
		up         = {0, 0, -1},
		fovy       = ext * 2,
		projection = .ORTHOGRAPHIC,
	}
	r.contact_range = {1, CONTACT_FAR, -10}
	draw_depth_pass(r, res, &r.contact, below, 1, CONTACT_FAR)
}

@(private)
ensure_mask :: proc(r: ^Renderer) {
	w := rl.GetRenderWidth()
	h := rl.GetRenderHeight()
	if r.mask.id != 0 && r.mask_w == w && r.mask_h == h {return}
	if r.mask.id != 0 {rl.UnloadRenderTexture(r.mask)}
	r.mask = rl.LoadRenderTexture(w, h)
	r.mask_w, r.mask_h = w, h
}

// Selection / hover mask, rendered before the main pass.
draw_mask :: proc(r: ^Renderer, res: ^model.Eval_Result, f: Frame) {
	ensure_mask(r)
	rl.BeginTextureMode(r.mask)
	rl.ClearBackground({0, 0, 0, 0})
	if f.highlighted {
		rlgl.SetClipPlanes(f64(f.near), f64(f.far))
		rl.BeginMode3D(f.camera)
		for rp, i in res.parts {
			sel := .Selected in f.flags[i]
			hov := .Hovered in f.flags[i]
			if !sel && !hov {continue}
			g := mesh_of(r, rp)
			if g == nil || g.mesh.vaoId == 0 {continue}
			r.flat_mat.maps[0].color = {sel ? 255 : 0, hov ? 255 : 0, 0, 255}
			rl.DrawMesh(g.mesh, r.flat_mat, rl.Matrix(rp.world))
		}
		rl.EndMode3D()
	}
	rl.EndTextureMode()
}

@(private)
bind_shadow_textures :: proc(r: ^Renderer) {
	rlgl.ActiveTextureSlot(SHADOW_SLOT)
	rlgl.EnableTexture(r.shadow.rt.depth.id)
	rlgl.ActiveTextureSlot(CONTACT_SLOT)
	rlgl.EnableTexture(r.contact.rt.depth.id)
	rlgl.ActiveTextureSlot(0)
}

draw_background :: proc() {
	// clears depth too: without it, last frame's depth carves holes into a moving view
	rl.ClearBackground({210, 213, 217, 255})
	w := rl.GetScreenWidth()
	h := rl.GetScreenHeight()
	rl.DrawRectangleGradientV(0, 0, w, h, {222, 225, 229, 255}, {196, 199, 203, 255})
}

// Main 3D pass. Call inside BeginDrawing, after draw_background.
draw_scene :: proc(r: ^Renderer, res: ^model.Eval_Result, f: Frame) {
	cam := f.camera
	bind_shadow_textures(r)
	rlgl.SetClipPlanes(f64(f.near), f64(f.far))
	rl.BeginMode3D(cam)

	c, rad := scene_radius(r)
	view_pos := cam.position

	// ground
	{
		gl := r.ground_locs
		light_vp := rl.Matrix(r.shadow.view_proj)
		contact_vp := rl.Matrix(r.contact.view_proj)
		rl.SetShaderValueMatrix(r.ground, gl.light_vp, light_vp)
		rl.SetShaderValueMatrix(r.ground, gl.contact_vp, contact_vp)
		rl.SetShaderValue(r.ground, gl.contact_range, &r.contact_range, .VEC3)
		rl.SetShaderValue(r.ground, gl.view_pos, &view_pos, .VEC3)
		gc := [3]f32{0.80, 0.80, 0.79}
		if f.show_room {gc = {0.62, 0.52, 0.42}}
		rl.SetShaderValue(r.ground, gl.ground_color, &gc, .VEC3)
		fc := [3]f32{0.79, 0.80, 0.81}
		rl.SetShaderValue(r.ground, gl.fade_color, &fc, .VEC3)
		fade := max(rad * 4, 4000)
		rl.SetShaderValue(r.ground, gl.fade_radius, &fade, .FLOAT)
		center := [2]f32{c.x, c.z}
		rl.SetShaderValue(r.ground, gl.scene_center, &center, .VEC2)
		grid: f32 = f.show_grid ? 1 : 0
		rl.SetShaderValue(r.ground, gl.show_grid, &grid, .FLOAT)
		rl.BeginShaderMode(r.ground)
		rlgl.DisableBackfaceCulling()
		y: f32 = -0.3
		x0, x1 := c.x - fade, c.x + fade
		z0, z1 := c.z - fade, c.z + fade
		rlgl.Begin(rlgl.QUADS)
		rlgl.Color4ub(255, 255, 255, 255)
		rlgl.Vertex3f(x0, y, z0)
		rlgl.Vertex3f(x0, y, z1)
		rlgl.Vertex3f(x1, y, z1)
		rlgl.Vertex3f(x1, y, z0)
		rlgl.End()
		rlgl.DrawRenderBatchActive()
		rlgl.EnableBackfaceCulling()
		rl.EndShaderMode()
	}

	// parts
	wl := r.wood_locs
	light_vp := rl.Matrix(r.shadow.view_proj)
	rl.SetShaderValueMatrix(r.wood, wl.light_vp, light_vp)
	ld := LIGHT_DIR
	rl.SetShaderValue(r.wood, wl.light_dir, &ld, .VEC3)
	rl.SetShaderValue(r.wood, wl.view_pos, &view_pos, .VEC3)
	rlgl.DisableBackfaceCulling() // open shapes / mirrored transforms stay visible
	for rp, i in res.parts {
		g := mesh_of(r, rp)
		if g == nil || g.mesh.vaoId == 0 {continue}
		kind := i32(rp.material.kind)
		rl.SetShaderValue(r.wood, wl.mat_kind, &kind, .INT)
		gr: f32 = rp.part.grain_rot ? 1 : 0
		rl.SetShaderValue(r.wood, wl.grain_rot, &gr, .FLOAT)
		seed := seed_of(rp.id)
		rl.SetShaderValue(r.wood, wl.seed, &seed, .FLOAT)
		tint := [4]f32{0, 0, 0, 0}
		if rp.errors > 0 {tint = {0.9, 0.2, 0.15, 0.35}}
		if .Ghost in f.flags[i] {tint = {0.95, 0.95, 0.95, 0.6}}
		rl.SetShaderValue(r.wood, wl.tint, &tint, .VEC4)
		r.wood_mat.maps[0].color = color_of(rp.material.color)
		rl.DrawMesh(g.mesh, r.wood_mat, rl.Matrix(rp.world))
	}

	// room backdrop: back wall and side wall hugging the scene
	if f.show_room {
		kind: i32 = 1
		rl.SetShaderValue(r.wood, wl.mat_kind, &kind, .INT)
		zero: f32 = 0
		rl.SetShaderValue(r.wood, wl.grain_rot, &zero, .FLOAT)
		tint := [4]f32{0, 0, 0, 0}
		rl.SetShaderValue(r.wood, wl.tint, &tint, .VEC4)
		r.wood_mat.maps[0].color = {238, 235, 228, 255}
		lo, hi := r.scene_lo, r.scene_hi
		H: f32 = max(2600, hi.y + 300)
		span: f32 = max(hi.x - lo.x, hi.z - lo.z) + 2600
		T: f32 = 40
		back := linalg.matrix4_translate_f32({lo.x - T + span * 0.5, H * 0.5 - 0.5, lo.z - T * 0.5 - 0.5}) * linalg.matrix4_scale_f32({span, H, T})
		side := linalg.matrix4_translate_f32({lo.x - T * 0.5 - 0.5, H * 0.5 - 0.5, lo.z - T + span * 0.5}) * linalg.matrix4_scale_f32({T, H, span})
		rl.DrawMesh(r.wall, r.wood_mat, rl.Matrix(back))
		rl.DrawMesh(r.wall, r.wood_mat, rl.Matrix(side))
	}
	rlgl.EnableBackfaceCulling()

	// feature edges, pulled slightly toward the camera through the projection
	if f.show_edges {
		rlgl.DrawRenderBatchActive()
		proj := rlgl.GetMatrixProjection()
		biased := Mat4(proj)
		eps: f32 = 0.00005
		for j in 0 ..< 4 {biased[2, j] -= eps * biased[3, j]}
		rlgl.SetMatrixProjection(rl.Matrix(biased))
		for rp in res.parts {
			g := mesh_of(r, rp)
			if g == nil || len(g.data.edges) == 0 {continue}
			m := rp.world
			flat := transmute([16]f32)m
			rlgl.PushMatrix()
			rlgl.MultMatrixf(&flat[0])
			rlgl.Begin(rlgl.LINES)
			rlgl.Color4ub(40, 32, 26, 120)
			for e in g.data.edges {rlgl.Vertex3f(e.x, e.y, e.z)}
			rlgl.End()
			rlgl.PopMatrix()
		}
		rlgl.DrawRenderBatchActive()
		rlgl.SetMatrixProjection(proj)
	}
	rl.EndMode3D()
}

// Composites the selection outline over the frame (2D, after draw_scene),
// limited to `area` (screen points) so small selections stay cheap.
draw_outline :: proc(r: ^Renderer, dpi: f32, area: rl.Rectangle) {
	if r.mask.id == 0 {return}
	ol := r.outline_locs
	texel := [2]f32{1 / f32(r.mask_w), 1 / f32(r.mask_h)}
	rl.SetShaderValue(r.outline, ol.texel, &texel, .VEC2)
	radius := 2.0 * dpi
	rl.SetShaderValue(r.outline, ol.radius, &radius, .FLOAT)
	sel := [4]f32{0.98, 0.55, 0.12, 1}
	hov := [4]f32{1.0, 0.78, 0.45, 0.85}
	rl.SetShaderValue(r.outline, ol.sel_color, &sel, .VEC4)
	rl.SetShaderValue(r.outline, ol.hover_color, &hov, .VEC4)
	rl.BeginShaderMode(r.outline)
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	x0 := clamp(area.x, 0, sw)
	y0 := clamp(area.y, 0, sh)
	x1 := clamp(area.x + area.width, 0, sw)
	y1 := clamp(area.y + area.height, 0, sh)
	if x1 <= x0 || y1 <= y0 {
		rl.EndShaderMode()
		return
	}
	// mask pixels per screen point, and the mask is stored bottom-up
	kx := f32(r.mask_w) / sw
	ky := f32(r.mask_h) / sh
	src := rl.Rectangle{x0 * kx, f32(r.mask_h) - y1 * ky, (x1 - x0) * kx, -(y1 - y0) * ky}
	dst := rl.Rectangle{x0, y0, x1 - x0, y1 - y0}
	rl.DrawTexturePro(r.mask.texture, src, dst, {}, 0, rl.WHITE)
	rl.EndShaderMode()
}

// Near/far planes that keep depth precision for a scene viewed from `dist`.
clip_planes :: proc(r: ^Renderer, cam_pos: Vec3) -> (near, far: f32) {
	c, rad := scene_radius(r)
	d := linalg.length(cam_pos - c)
	far = d + rad * 8 + 20000
	near = max(1, (d - rad * 2) * 0.05)
	near = min(near, 50)
	return
}
