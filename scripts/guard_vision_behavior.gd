extends Node3D

@export var cone_mesh_instance: MeshInstance3D

@export var view_distance: float = 12.0
@export var view_angle_deg: float = 60.0
@export var memory_duration: float = 2.0

@export var detection_speed: float = 2.5
# Detection speed multiplier at the far edge of view_distance. 1.0 = no
# distance falloff, 0.0 = no detection at the edge. Detection is interpolated
# linearly between full speed (player at 0 m) and this value (player at view_distance).
@export_range(0.0, 1.0) var detection_falloff_min: float = 0.1
@export var show_debug_cone: bool = true

var player: Node3D

var detection_strength := 0.0

var last_seen_time := 0.0
var last_known_position: Vector3
var has_memory := false

# Player velocity tracking (used by the chase influence-map solver)
var last_known_velocity: Vector3 = Vector3.ZERO
var _previous_player_position: Vector3
var _has_previous_position: bool = false

@onready var guard: CharacterBody3D = get_parent()


func _ready():
	player = get_tree().get_first_node_in_group("Player")


func _physics_process(delta):
	var seen_now = _can_see_player()
	var now = Time.get_ticks_msec() / 1000.0

	# -------------------------------------------------
	# Smooth detection buildup / decay
	# -------------------------------------------------
	if seen_now:
		# Distance falloff — closer player = faster detection.
		var dist: float = guard.global_position.distance_to(player.global_position)
		var t: float = clamp(dist / view_distance, 0.0, 1.0)
		var dist_factor: float = lerp(1.0, detection_falloff_min, t)
		detection_strength += detection_speed * dist_factor * player.get_visibility()
		last_seen_time = now
		# Estimate player velocity from successive sightings
		if _has_previous_position and delta > 0.0:
			last_known_velocity = (player.global_position - _previous_player_position) / delta
		_previous_player_position = player.global_position
		_has_previous_position = true
		last_known_position = player.global_position
		has_memory = true
	else:
		detection_strength -= detection_speed * delta
		# Reset the previous-position cache so a stale value isn't used
		# next time the player re-enters the cone after a long gap.
		_has_previous_position = false

	detection_strength = clamp(detection_strength, 0.0, 1.0)

	# Memory timeout
	if now - last_seen_time > memory_duration:
		has_memory = false

	_update_debug_cone()


# =====================================================
# PUBLIC API
# =====================================================
func can_see_player() -> bool:
	return detection_strength >= 1.0


func get_detection_strength() -> float:
	return detection_strength


func get_last_known_position() -> Vector3:
	return last_known_position


func get_last_known_velocity() -> Vector3:
	return last_known_velocity


func has_target_memory() -> bool:
	return has_memory


# =====================================================
# VISION LOGIC
# =====================================================
func _can_see_player() -> bool:
	if player == null:
		return false

	var to_player = player.global_position - guard.global_position
	var distance = to_player.length()

	# Distance check
	if distance > view_distance:
		return false

	# Angle check
	var forward = -guard.global_transform.basis.z.normalized()
	var direction = to_player.normalized()

	var dot = clamp(forward.dot(direction), -1.0, 1.0)
	var angle = rad_to_deg(acos(dot))

	if angle > view_angle_deg * 0.5:
		return false

	# Raycast
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(
		guard.global_position,
		player.global_position
	)

	query.exclude = [guard]

	var result = space_state.intersect_ray(query)

	if result and not result.collider.is_in_group("Player"):
		return false

	return true


# =====================================================
# DEBUG CONE (EDITOR PLACED)
# =====================================================
func _update_debug_cone():
	if not show_debug_cone or cone_mesh_instance == null:
		return

	var mesh := cone_mesh_instance.mesh as CylinderMesh
	if mesh:
		mesh.height = view_distance
		mesh.bottom_radius = max(0.05, view_distance * tan(deg_to_rad(view_angle_deg * 0.5)))
		cone_mesh_instance.position = Vector3(0, 0, -view_distance * 0.5)

	# -------------------------
	# MATERIAL (requested method)
	# -------------------------
	var mat := cone_mesh_instance.get_surface_override_material(0)

	if mat == null:
		mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cone_mesh_instance.set_surface_override_material(0, mat)

	# Smooth color blending (green → red)
	var green = Color(0, 1, 0, 0.2)
	var red = Color(1, 0, 0, 0.4)

	mat.albedo_color = green.lerp(red, detection_strength)
