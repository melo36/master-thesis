extends CharacterBody3D

@onready var noise_sensor: Node3D = $NoiseSensor
@onready var vision_sensor: Node3D = $VisionSensor
@onready var guard_movement: Node3D = $GuardMovement

enum State {
	PATROL,
	INVESTIGATE,
	CHASE
}

var current_state: State = State.PATROL

func _physics_process(delta):
	_update_state()
	_execute_state()
	

func _update_state():
	# 1. Vision overrides everything
	if vision_sensor.get_detection_strength() >= 1.0:
		current_state = State.CHASE
		print("Chase")
		return

	# 2. Sound if no vision
	if noise_sensor.get_sound_strength() > 0.2:
		current_state = State.INVESTIGATE
		print("Investigate")
		return
	# 3. Default
	print("Patrol")
	current_state = State.PATROL
	
func _execute_state():
	match current_state:
		State.PATROL:
			guard_movement.set_state(guard_movement.State.PATROL)

		State.INVESTIGATE:
			guard_movement.set_state(guard_movement.State.INVESTIGATE, noise_sensor.get_last_sound_position())

		State.CHASE:
			guard_movement.set_state(guard_movement.State.CHASE, vision_sensor.get_last_known_position())

func investigate_sound(target_position: Vector3):
	noise_sensor.register_sound(target_position)
