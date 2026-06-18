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
	
	var env_sounds = get_environment_noise()
	print("Env sounds, ", env_sounds)
	# Accumulate instead of overwrite
	sound_strength += strength - env_sounds
	print("Sound strength", sound_strength)
	sound_strength = clamp(sound_strength, 0.0, max_strength)
	return sound_strength

func get_environment_noise() -> float:
	var noise = 0.0

	for source in get_tree().get_nodes_in_group("EnvironmentSounds"):
		var distance = global_position.distance_to(source.global_position)

		if distance < 20:
			noise += source.audio_player.get_volume_db_from_pos(global_position)

	return noise

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
