extends Node3D

var last_sound_position: Vector3

# Continuous sound interest instead of boolean
var sound_strength: float = 0.0

@export var max_strength: float = 1.0
@export var decay_rate: float = 0.5  # per second


func _physics_process(delta):
	_decay(delta)


# -------------------------
# REGISTER SOUND
# -------------------------
func register_sound(pos: Vector3, strength: float = 1.0):
	last_sound_position = pos
	
	# Accumulate instead of overwrite
	sound_strength += strength
	sound_strength = clamp(sound_strength, 0.0, max_strength)


# -------------------------
# DECAY
# -------------------------
func _decay(delta):
	sound_strength -= decay_rate * delta
	sound_strength = max(sound_strength, 0.0)


# -------------------------
# GETTERS (for your brain)
# -------------------------
func get_last_sound_position() -> Vector3:
	return last_sound_position


func get_sound_strength() -> float:
	return sound_strength


func has_recent_sound(threshold: float = 0.01) -> bool:
	return sound_strength > threshold
