extends Area3D

@onready var lock_on_radius: Area3D = $"."
@onready var projectile_spawn = $"../ShurikenSpawn"
@onready var shuriken: Area3D = $"../Shuriken"
var current_target: Node3D = null

func _process(_delta):
	current_target = get_best_target()
	if current_target:
		# Here you can update UI/Reticle over the current_target's head
		pass

func get_best_target() -> Node3D:
	var overlapping_bodies = lock_on_radius.get_overlapping_bodies()
	var best_target: Node3D = null
	var closest_distance = INF
	
	for body in overlapping_bodies:
		if body.is_in_group("Guard"):
			# Ensure the guard isn't behind a wall before locking on
			if has_clear_line_of_sight(body):
				var distance = global_position.distance_to(body.global_position)
				if distance < closest_distance:
					closest_distance = distance
					best_target = body
					
	return best_target

func has_clear_line_of_sight(target: Node3D) -> bool:
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsRayQueryParameters3D.create(global_position + Vector3.UP, target.global_position + Vector3.UP)
	query.exclude = [self]
	var result = space_state.intersect_ray(query)
	
	if result and result.collider == target:
		return true
	return false

func _unhandled_input(event):
	if event.is_action_pressed("throw_weapon") and current_target:
		throw_shuriken()

func throw_shuriken():
	# Start the projectile at the spawn marker and pass the target reference
	shuriken.visible = true
	shuriken.global_position = projectile_spawn.global_position
	shuriken.launch(current_target)
