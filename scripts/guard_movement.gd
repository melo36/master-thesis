extends Node3D

@onready var guard: CharacterBody3D = $".."
@onready var navigation_agent_3d: NavigationAgent3D = $"../NavigationAgent3D"
@export var speed = 5
# Speed multiplier applied while CHASE-ing or SEARCH_LOST-ing (the brain
# routes SEARCH_LOST through CHASE), to make the guard feel threatening.
@export var chase_speed_multiplier: float = 1.5
@onready var patrol_points = $"../../PatrolRoute".get_children()
@export var tolerance = 5

var current_index := 0

var current_target: Vector3

enum State {
	PATROL,
	INVESTIGATE,
	CHASE,
	DEFAULT,
	DEAD
}

var state: State = State.PATROL
var target_position: Vector3
var has_target := false

func set_state(new_state: State, target: Vector3 = Vector3.ZERO):
	if new_state == State.DEAD:
		state = State.DEAD
		return
	
	if state != new_state:
		state = State.DEFAULT
		guard.velocity = Vector3(0,0,0)
		await get_tree().create_timer(1.0).timeout
		
	state = new_state

	if state == State.INVESTIGATE:
		current_index = 0
		target_position = target
		has_target = true

	elif state == State.CHASE:
		current_index = 0
		target_position = target
		has_target = true

func _physics_process(delta: float) -> void:
	if state == State.PATROL:
		# Patrol logic
		if guard.global_position.distance_to(current_target) <= tolerance || current_index == 0:
			current_target = get_next_patrol_point()
			navigation_agent_3d.set_target_position(current_target)
		
		var destination = navigation_agent_3d.get_next_path_position()
		var direction = (destination - guard.global_position).normalized()
		
		# Movement
		guard.velocity = direction * speed
		guard.move_and_slide()
		
		# Rotation
		if direction.length() > 0.01:
			var target_rotation = atan2(direction.x, direction.z) + PI
			guard.rotation.y = lerp_angle(guard.rotation.y, target_rotation, 5 * delta)
			
	elif state == State.INVESTIGATE:
		move_along_nav(delta, speed)

	elif state == State.CHASE:
		move_along_nav(delta, speed * chase_speed_multiplier)
		
	elif state == State.DEFAULT:
		var direction = (target_position - guard.global_position).normalized()
	
		# Rotation
		if direction.length() > 0.01:
			var target_rotation = atan2(direction.x, direction.z) + PI
			guard.rotation.y = lerp_angle(guard.rotation.y, target_rotation, 5 * delta)
	
	elif state == State.DEAD:
		navigation_agent_3d.set_target_position(global_position)
		guard.velocity = Vector3.ZERO
	
func get_next_patrol_point() -> Vector3:
	var point = patrol_points[current_index].global_position
	current_index = (current_index + 1) % patrol_points.size()
	return point

func move_along_nav(delta: float, move_speed: float = speed):
	navigation_agent_3d.set_target_position(target_position)
	var next = navigation_agent_3d.get_next_path_position()
	var direction = (next - guard.global_position).normalized()

	# Rotation
	if direction.length() > 0.01:
		var target_rotation = atan2(direction.x, direction.z) + PI
		guard.rotation.y = lerp_angle(guard.rotation.y, target_rotation, 5 * delta)

	guard.velocity = direction * move_speed
	guard.move_and_slide()
