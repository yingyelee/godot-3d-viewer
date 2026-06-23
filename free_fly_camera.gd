extends Camera3D
## Free-fly camera for inspecting 3D models in the viewer.
## Controls:
##   - Hold right mouse button + move mouse : look around
##   - W / S : move forward / backward
##   - A / D : strafe left / right
##   - Q / E : move down / up
##   - Shift : move faster
##   - Esc   : release / capture mouse

@export var move_speed: float = 4.0
@export var sprint_multiplier: float = 4.0
@export var look_sensitivity: float = 0.003
## Touch-drag rotation sensitivity. A bit higher than mouse because finger
## drags are usually slower but cover more screen distance per second.
@export_range(0.0005, 0.02, 0.0005) var touch_look_sensitivity: float = 0.006
@export var initial_position: Vector3 = Vector3(0, 1.5, 0.1)
@export var auto_capture_mouse: bool = true
## If set, the camera frames this node's AABB on start. Leave empty to use `initial_position`.
@export var auto_frame_target: NodePath
## FOV zoom settings (smaller FOV = more zoomed in).
@export_range(1.0, 120.0, 0.5) var fov_min: float = 15.0
## Upper bound on FOV. A wider FOV means more of the scene is visible at once,
## which can pull empty space into the frame. 55° keeps the model large in the
## view without being too narrow to inspect it.
@export_range(1.0, 120.0, 0.5) var fov_max: float = 55.0
@export_range(0.5, 30.0, 0.5) var fov_step: float = 5.0
## Pinch zoom sensitivity (lower = less sensitive).
@export_range(0.05, 2.0, 0.05) var pinch_sensitivity: float = 0.5
## If true, the camera is clamped to a padded AABB around the model so the user
## can't fly out into the empty scene. The bounds are derived from the
## `auto_frame_target` node (or the model root if that's empty).
@export var clamp_to_model_bounds: bool = true
## Extra room (in world units, on every side) added to the model's AABB when
## clamping. Keep this small (0-1) so the camera stays close to the model and
## the view never extends past it into the void.
@export var bounds_padding: float = 0.3
## Hard ceiling on how high the camera can fly above the model's top.
@export var bounds_max_height_above_model: float = 4.0
## Hard floor on how far below the model's bottom the camera can drop.
@export var bounds_min_height_below_model: float = 0.3
## Minimum pitch (radians). -PI/2 means looking straight down. We use this to
## keep the view from rotating to angles that show the empty scene around the
## model.
@export_range(-1.5707, 0.0, 0.01) var pitch_min: float = -1.5707
## Maximum pitch (radians). 0 means horizontal. Keep this negative so the
## camera always looks somewhat downward at the model. Combined with
## `pitch_min` this gives a total pitch range of 0.3 rad (~17°), which
## keeps the view almost locked in a near-top-down inspection angle.
@export_range(-1.5707, 0.0, 0.01) var pitch_max: float = -1.2707
## Minimum yaw (radians). Left turn limit. Symmetric around 0, total left-right range ~20° (~0.349 rad).
@export_range(-3.1416, 3.1416, 0.01) var yaw_min: float = -0.175
## Maximum yaw (radians). Right turn limit.
@export_range(-3.1416, 3.1416, 0.01) var yaw_max: float = 0.175
## Mobile gravity / gyroscope look. Uses the device gyroscope when available.
@export var tilt_enabled: bool = true
## Multiplier for gyroscope rotation rate.
@export_range(0.1, 5.0, 0.1) var tilt_sensitivity: float = 1.0
## Threshold (rad/s) below which gyro noise is ignored.
@export_range(0.0, 0.5, 0.005) var tilt_deadzone: float = 0.02
## Threshold (degrees) below which device tilt changes are ignored on web.
@export_range(0.0, 5.0, 0.1) var tilt_web_deadzone_deg: float = 0.5
## If true, enabling tilt snaps yaw/pitch back to (0, 0). Default off so the
## camera keeps the user's current view across toggles.
@export var tilt_recenter_on_enable: bool = false

var _yaw: float = 0.0
var _pitch: float = 0.0
var _mouse_captured: bool = false
# Multi-touch tracking: index -> position.
var _touches: Dictionary = {}
# Last measured distance between the first two active fingers.
var _last_pinch_dist: float = 0.0
# Last screen position of the single active finger, used to compute drag delta.
var _last_single_finger_pos: Vector2 = Vector2.ZERO
# True while gyroscope-driven look is active.
var _tilt_active: bool = false
# Cached baseline of the device orientation captured when tilt is enabled.
# On web this comes from `deviceorientation` beta/gamma (degrees).
var _tilt_baseline_beta: float = 0.0
var _tilt_baseline_gamma: float = 0.0
var _tilt_baseline_captured: bool = false
# Cached world-space AABB of the model, used for camera clamping.
# Empty AABB (size = 0) means "not yet computed" and the clamp becomes a no-op.
var _model_aabb: AABB = AABB()


func _ready() -> void:
	# Wait one frame so children / instances have computed their AABBs.
	await get_tree().process_frame
	_auto_frame_if_needed()
	_refresh_model_aabb()

	if tilt_enabled:
		set_tilt(true)

	if auto_capture_mouse:
		capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	# Toggle mouse capture with Escape.
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _mouse_captured:
			release_mouse()
		else:
			capture_mouse()
		return

	# Mouse wheel zoom (works even when mouse is not captured).
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_in()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_out()
			return

	# Right mouse button toggles look mode (only when not already captured).
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				capture_mouse()
			else:
				release_mouse()
			return

	# While captured, mouse motion rotates the camera.
	if _mouse_captured and event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		_yaw -= motion.relative.x * look_sensitivity
		_pitch -= motion.relative.y * look_sensitivity
		_pitch = clamp(_pitch, pitch_min, pitch_max)
		_apply_rotation()

	# Touch: track active fingers.
	# - 1 finger : drag to look around
	# - 2 fingers : pinch to zoom
	if event is InputEventScreenTouch:
		var t: InputEventScreenTouch = event
		if t.pressed:
			_touches[t.index] = t.position
			# When we go from 1 -> 2 fingers, reset the rotation tracking
			# so the next single-finger drag starts cleanly.
			if _touches.size() == 2:
				_last_single_finger_pos = Vector2.ZERO
		else:
			_touches.erase(t.index)
			if _touches.size() < 2:
				_last_pinch_dist = 0.0
			if _touches.size() == 1:
				# Re-seed single-finger tracking with the remaining finger.
				_last_single_finger_pos = _touches.values()[0]
		return

	if event is InputEventScreenDrag:
		var d: InputEventScreenDrag = event
		_touches[d.index] = d.position
		if _touches.size() >= 2:
			var pts: Array = _touches.values()
			var dist: float = (pts[0] - pts[1]).length()
			if _last_pinch_dist > 0.0001 and dist > 0.0001:
				# Pinch out (fingers spread) => zoom in (smaller fov).
				# Pinch in (fingers close) => zoom out (larger fov).
				var ratio: float = _last_pinch_dist / dist
				fov = clamp(fov * ratio, fov_min, fov_max)
			_last_pinch_dist = dist
			_last_single_finger_pos = Vector2.ZERO
		elif _touches.size() == 1:
			# Single-finger drag -> rotate the camera. Use a touch sensitivity
			# that's a bit higher than the mouse since finger drags are usually
			# larger and slower.
			if _last_single_finger_pos != Vector2.ZERO:
				var delta_pos: Vector2 = d.position - _last_single_finger_pos
				_yaw -= delta_pos.x * touch_look_sensitivity
				_pitch -= delta_pos.y * touch_look_sensitivity
				_pitch = clamp(_pitch, pitch_min, pitch_max)
				_apply_rotation()
			_last_single_finger_pos = d.position
		return


func _process(delta: float) -> void:
	# Integrate the gyroscope (mobile gravity / tilt look).
	if _tilt_active:
		_process_tilt(delta)

	var input_vec: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input_vec.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input_vec.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input_vec.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input_vec.x += 1.0
	if Input.is_key_pressed(KEY_E):
		input_vec.y += 1.0
	if Input.is_key_pressed(KEY_Q):
		input_vec.y -= 1.0

	if input_vec == Vector3.ZERO:
		return

	input_vec = input_vec.normalized()
	var speed: float = move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= sprint_multiplier

	# Convert local input to world-space motion using the camera basis.
	var basis_xform: Basis = global_transform.basis
	var forward: Vector3 = - basis_xform.z
	var right: Vector3 = basis_xform.x
	var up: Vector3 = Vector3.UP

	# Flatten forward/right so movement stays horizontal when not holding Q/E.
	forward.y = 0.0
	forward = forward.normalized()
	right.y = 0.0
	right = right.normalized()

	var motion: Vector3 = (forward * -input_vec.z) + (right * input_vec.x) + (up * input_vec.y)
	global_position += motion * speed * delta
	_clamp_to_model_bounds()


func capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_mouse_captured = true


func release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_mouse_captured = false


func zoom_in() -> void:
	fov = clamp(fov - fov_step, fov_min, fov_max)


func zoom_out() -> void:
	fov = clamp(fov + fov_step, fov_min, fov_max)


## Enable / disable the gyroscope-based "tilt to look" feature.
## On enable we optionally re-center so the device's current pose is neutral.
## Sensors must be enabled in Project Settings -> Input Devices -> Sensors
## (`sensors/enable_gyroscope` and `sensors/enable_accelerometer`).
## NOTE: Godot 4's `Input.get_gyroscope()` is a no-op on HTML5, so on web we
## read `deviceorientation` events via JavaScriptBridge instead.
func set_tilt(enabled: bool, recenter: bool = true) -> void:
	tilt_enabled = enabled
	if enabled:
		# On iOS 13+ Safari the browser requires an explicit user-gesture
		# permission request before motion sensors can be read. We trigger it
		# synchronously from the click handler so the user-gesture context
		# is preserved. On other platforms this is a no-op.
		_request_sensor_permission()
		if recenter and tilt_recenter_on_enable:
			# Reset to a known neutral orientation.
			_yaw = 0.0
			_pitch = 0.0
			_apply_rotation()
		# The first reading after this point is taken as the baseline in
		# `_process_tilt_web()`, so subsequent tilt is measured relative to
		# the device's current pose.
		_tilt_baseline_captured = false
		_tilt_active = true
	else:
		_tilt_active = false


func _request_sensor_permission() -> void:
	if not OS.has_feature("web"):
		return
	if not Engine.has_singleton("JavaScriptBridge"):
		return
	# iOS 13+ Safari: must call DeviceMotionEvent.requestPermission() (and
	# DeviceOrientationEvent.requestPermission()) from a user-gesture handler.
	# On all other browsers we just attach the event listeners directly.
	# We expose the latest orientation at `window.__gyroData` for the GDScript
	# side to poll in `_process_tilt`.
	var js: String = """
	(function() {
		window.__gyroData = window.__gyroData || {alpha: 0, beta: 0, gamma: 0, hasData: false};

		function onOrientation(event) {
			window.__gyroData.alpha = (event.alpha == null ? 0 : event.alpha);
			window.__gyroData.beta  = (event.beta  == null ? 0 : event.beta);
			window.__gyroData.gamma = (event.gamma == null ? 0 : event.gamma);
			window.__gyroData.hasData = true;
		}

		function attach() {
			if (window.__gyroListenerAttached) return;
			window.addEventListener('deviceorientation', onOrientation, true);
			window.__gyroListenerAttached = true;
		}

		if (window.__gyroInitialized) {
			// Already initialized: re-request permission (must be in a user
			// gesture). If the user grants this time, attach the listener.
			if (typeof DeviceOrientationEvent !== 'undefined' && typeof DeviceOrientationEvent.requestPermission === 'function') {
				DeviceOrientationEvent.requestPermission().then(function(state) {
					window.__sensorPermission = state;
					if (state === 'granted') {
						attach();
					}
				}).catch(function() {
					window.__sensorPermission = 'denied';
				});
			}
			return;
		}
		window.__gyroInitialized = true;

		if (typeof DeviceOrientationEvent !== 'undefined' && typeof DeviceOrientationEvent.requestPermission === 'function') {
			DeviceOrientationEvent.requestPermission().then(function(state) {
				window.__sensorPermission = state;
				if (state === 'granted') {
					attach();
				}
			}).catch(function() {
				window.__sensorPermission = 'denied';
			});
		} else {
			window.__sensorPermission = 'granted';
			attach();
		}
	})();
	"""
	JavaScriptBridge.eval(js, true)


func _process_tilt(delta: float) -> void:
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		_process_tilt_web()
	else:
		_process_tilt_native(delta)


func _process_tilt_web() -> void:
	# Poll the latest absolute device orientation. We integrate the per-frame
	# delta instead of using absolute orientation directly, so the camera
	# position is purely additive and the user can toggle tilt on/off without
	# the view jumping.
	var js: String = "JSON.stringify({b: (window.__gyroData ? window.__gyroData.beta : 0), g: (window.__gyroData ? window.__gyroData.gamma : 0), h: (window.__gyroData ? window.__gyroData.hasData : false)})"
	var result: Variant = JavaScriptBridge.eval(js, true)
	if not (result is String):
		return
	var data: Variant = JSON.parse_string(result)
	if not (data is Dictionary) or not data.get("h", false):
		return

	var beta: float = float(data.get("b", 0.0))
	var gamma: float = float(data.get("g", 0.0))

	if not _tilt_baseline_captured:
		# First valid reading - record as the starting point and don't move.
		_tilt_baseline_beta = beta
		_tilt_baseline_gamma = gamma
		_tilt_baseline_captured = true
		return

	var beta_delta: float = beta - _tilt_baseline_beta
	var gamma_delta: float = gamma - _tilt_baseline_gamma
	_tilt_baseline_beta = beta
	_tilt_baseline_gamma = gamma

	# Deadzone in degrees.
	if abs(beta_delta) < tilt_web_deadzone_deg:
		beta_delta = 0.0
	if abs(gamma_delta) < tilt_web_deadzone_deg:
		gamma_delta = 0.0

	if beta_delta == 0.0 and gamma_delta == 0.0:
		return

	# Add to the current camera rotation. `beta` is front/back tilt -> pitch;
	# `gamma` is left/right tilt -> yaw.
	_yaw += deg_to_rad(-gamma_delta) * tilt_sensitivity
	_pitch = clamp(_pitch + deg_to_rad(beta_delta) * tilt_sensitivity, pitch_min, pitch_max)
	_apply_rotation()


func _process_tilt_native(delta: float) -> void:
	var gyro: Vector3 = Input.get_gyroscope()
	# Apply deadzone per-axis to suppress jitter while the device is still.
	if abs(gyro.x) < tilt_deadzone:
		gyro.x = 0.0
	if abs(gyro.y) < tilt_deadzone:
		gyro.y = 0.0
	if abs(gyro.z) < tilt_deadzone:
		gyro.z = 0.0

	if gyro == Vector3.ZERO:
		return

	# Device axes (portrait):
	#   gyro.x -> rotation around X (pitch up/down on the device)
	#   gyro.y -> rotation around Y (roll left/right)
	#   gyro.z -> rotation around Z (yaw left/right)
	# We map yaw from gyro.z and pitch from gyro.y.
	var step_yaw: float = - gyro.z * tilt_sensitivity * delta
	var step_pitch: float = - gyro.y * tilt_sensitivity * delta

	_yaw += step_yaw
	_pitch = clamp(_pitch + step_pitch, pitch_min, pitch_max)
	_apply_rotation()


func _apply_rotation() -> void:
	# Clamp yaw to keep the view roughly facing the model.
	_yaw = clamp(_yaw, yaw_min, yaw_max)
	# Build a fresh rotation from yaw/pitch and apply it to the global transform
	# (keeps the configured initial_position intact).
	var basis_out: Basis = Basis().rotated(Vector3.UP, _yaw).rotated(Vector3.RIGHT, _pitch)
	var t: Transform3D = global_transform
	t.basis = basis_out
	global_transform = t


func _auto_frame_if_needed() -> void:
	# Default: place the camera at `initial_position` and look straight down.
	global_position = initial_position
	# Force pitch = -90° (looking down) and yaw = 0 (facing -Z).
	_yaw = 0.0
	_pitch = - PI / 2.0
	_apply_rotation()


# Compute the world-space AABB of the model and cache it for clamping.
# If `auto_frame_target` is set we use that node, otherwise we fall back to
# the scene's first MeshInstance3D's parent chain.
func _refresh_model_aabb() -> void:
	if not clamp_to_model_bounds:
		_model_aabb = AABB()
		return
	var target: Node3D = null
	if auto_frame_target != NodePath(""):
		var n: Node = get_node_or_null(auto_frame_target)
		if n is Node3D:
			target = n
	if target == null:
		# Walk up the scene tree from the camera until we find a node with
		# MeshInstance3D children. Fall back to the first MeshInstance3D.
		var found: MeshInstance3D = _find_first_mesh_instance(get_tree().current_scene)
		if found:
			target = found
	if target == null:
		_model_aabb = AABB()
		return
	_model_aabb = _compute_world_aabb(target)


func _clamp_to_model_bounds() -> void:
	if not clamp_to_model_bounds:
		return
	if _model_aabb.size == Vector3.ZERO:
		return
	var pad: float = bounds_padding
	var min_x: float = _model_aabb.position.x - pad
	var min_y: float = _model_aabb.position.y - bounds_min_height_below_model
	var min_z: float = _model_aabb.position.z - pad
	var max_x: float = _model_aabb.end.x + pad
	var max_y: float = _model_aabb.end.y + bounds_max_height_above_model
	var max_z: float = _model_aabb.end.z + pad
	var p: Vector3 = global_position
	p.x = clamp(p.x, min_x, max_x)
	p.y = clamp(p.y, min_y, max_y)
	p.z = clamp(p.z, min_z, max_z)
	if p != global_position:
		global_position = p


func _find_first_mesh_instance(root: Node) -> MeshInstance3D:
	if root is MeshInstance3D:
		return root
	for child in root.get_children():
		var found: MeshInstance3D = _find_first_mesh_instance(child)
		if found:
			return found
	return null


# Recursively combine the world-space AABBs of every MeshInstance3D under `root`.
func _compute_world_aabb(root: Node3D) -> AABB:
	var acc: _AABBAccum = _AABBAccum.new()
	_collect_aabb(root, acc)
	return acc.to_aabb()


func _collect_aabb(node: Node, acc: _AABBAccum) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		if mi.mesh:
			var local_aabb: AABB = mi.get_aabb()
			# Transform the 8 corners into world space and merge.
			var xf: Transform3D = mi.global_transform
			var corners: PackedVector3Array = [
				xf * Vector3(local_aabb.position.x, local_aabb.position.y, local_aabb.position.z),
				xf * Vector3(local_aabb.end.x, local_aabb.position.y, local_aabb.position.z),
				xf * Vector3(local_aabb.position.x, local_aabb.end.y, local_aabb.position.z),
				xf * Vector3(local_aabb.end.x, local_aabb.end.y, local_aabb.position.z),
				xf * Vector3(local_aabb.position.x, local_aabb.position.y, local_aabb.end.z),
				xf * Vector3(local_aabb.end.x, local_aabb.position.y, local_aabb.end.z),
				xf * Vector3(local_aabb.position.x, local_aabb.end.y, local_aabb.end.z),
				xf * Vector3(local_aabb.end.x, local_aabb.end.y, local_aabb.end.z),
			]
			for c in corners:
				acc.add(c)
	for child in node.get_children():
		_collect_aabb(child, acc)


# Mutable accumulator so we can build an AABB across recursive calls.
class _AABBAccum:
	var has_any: bool = false
	var _aabb: AABB = AABB()

	func add(p: Vector3) -> void:
		if not has_any:
			_aabb = AABB(p, Vector3.ZERO)
			has_any = true
		else:
			_aabb = _aabb.expand(p)

	func to_aabb() -> AABB:
		return _aabb
