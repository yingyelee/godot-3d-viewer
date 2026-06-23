extends PanelContainer
## Small top-left zoom / tilt UI. Wires its buttons to a target camera.

@export var camera_path: NodePath

@onready var _btn_in: Button = %ZoomIn
@onready var _btn_out: Button = %ZoomOut
@onready var _btn_tilt: Button = %TiltToggle


func _ready() -> void:
	_btn_in.pressed.connect(_on_zoom_in_pressed)
	_btn_out.pressed.connect(_on_zoom_out_pressed)
	_btn_tilt.toggled.connect(_on_tilt_toggled)
	# Reflect the camera's current tilt state in the button.
	var cam: Node = get_node_or_null(camera_path)
	if cam:
		var pressed: bool = bool(cam.get("tilt_enabled"))
		_btn_tilt.button_pressed = pressed
		_update_tilt_label(pressed)


func _on_zoom_in_pressed() -> void:
	var cam: Node = get_node_or_null(camera_path)
	if cam and cam.has_method("zoom_in"):
		cam.zoom_in()


func _on_zoom_out_pressed() -> void:
	var cam: Node = get_node_or_null(camera_path)
	if cam and cam.has_method("zoom_out"):
		cam.zoom_out()


func _on_tilt_toggled(pressed: bool) -> void:
	var cam: Node = get_node_or_null(camera_path)
	if cam and cam.has_method("set_tilt"):
		cam.set_tilt(pressed)
	_update_tilt_label(pressed)


func _update_tilt_label(pressed: bool) -> void:
	_btn_tilt.text = "Gyro On" if pressed else "Gyro Off"
