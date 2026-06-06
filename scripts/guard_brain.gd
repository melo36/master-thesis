extends CharacterBody3D

@onready var noise_sensor: Node3D = $NoiseSensor
@onready var vision_sensor: Node3D = $VisionSensor
@onready var guard_movement: Node3D = $GuardMovement
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var chase_solver: ChaseInfluenceMap = $ChaseInfluenceMap
@onready var state_indicator: Label3D = $StateIndicator
@onready var vision_cone: MeshInstance3D = $VisionCone
@onready var shuriken_indicator: Sprite3D = $ShurikenIndicator
@onready var player: CharacterBody3D = $"../../Player"
@onready var muzzle_raycast: RayCast3D = $MuzzleRaycast
@onready var gun_sound_player: RaytracedAudioPlayer3D = $GunSoundPlayer

var animationTree
var state_machine

var dead: bool = false

enum State {
	PATROL,
	INVESTIGATE,
	CHASE,
	SHOOT,                # NEW: Combat shooting state
	SEARCH_LOST    # Pursuing the player after losing sight, using the influence-map flood
}

var current_state: State = State.PATROL
var previous_state: State = State.PATROL

# --- SEARCH_LOST tracking ---
var _search_destination: Vector3 = Vector3.ZERO
var _has_search_destination: bool = false
var _solver_pending: bool = false
var _search_started_at: float = 0.0
@export var wall_hacks: float = 3.0 # Changed to float for precise time evaluation

# --- NEW COMBAT/SHOOTING CONFIGURATIONS ---
@export var attack_range: float = 15.0       # Max distance from which the guard will shoot
@export var fire_rate: float = 1.5           # Time in seconds between consecutive shots
@export var aiming_windup: float = 0.5       # Time given to the player to dive into cover before the first shot

var _fire_timer: float = 0.0
# ------------------------------------------

# How close the guard must be to its search destination to consider the search done
@export var search_arrival_tolerance: float = 1.0
# A noise this loud will interrupt SEARCH_LOST and switch to INVESTIGATE.
@export var search_noise_interrupt: float = 1.5
# Minimum time to commit to SEARCH_LOST before any exit path is allowed.
@export var min_search_duration: float = 5.0

# --- INVESTIGATE CONFIGURATION ---
@export var investigate_arrival_tolerance: float = 1.0  # Distance to consider destination reached


func _ready() -> void:
	# Defer one physics frame so the navigation map is fully synced.
	await get_tree().physics_frame
	chase_solver.navigation_map = nav_agent.get_navigation_map()
	chase_solver.chase_destination_ready.connect(_on_search_destination_ready)
	chase_solver.chase_failed.connect(_on_search_failed)
	animationTree = $model/AnimationTree
	state_machine = animationTree.get("parameters/playback")


func _physics_process(delta):
	if dead:
		return
	_update_state()
	_execute_state(delta) # Passed delta here to run the weapon reload countdown
	handle_animation()


func _update_state():
	previous_state = current_state

	# 1. Vision overrides everything 
	if vision_sensor.get_detection_strength() >= 1.0:
		if current_state == State.SEARCH_LOST:
			_reset_search()
		
		# Reset the tracking timestamp since we actively have sight of the player
		_search_started_at = 0.0
		
		# Tactical Evaluation: Shoot or Chase?
		var dist_to_player = global_position.distance_to(player.global_position)
		if dist_to_player <= attack_range:
			if current_state != State.SHOOT:
				# Just entered combat state: apply temporary aim windup penalty
				_fire_timer = aiming_windup
			current_state = State.SHOOT
		else:
			current_state = State.CHASE
		return

	# 2. Wall hacks tracking phase (Triggers if sight is broken while in CHASE or SHOOT)
	if current_state == State.CHASE or current_state == State.SHOOT:
		if _search_started_at == 0.0:
			_search_started_at = (Time.get_ticks_msec() / 1000.0)
		var elapsed = (Time.get_ticks_msec() / 1000.0) - _search_started_at
		
		if elapsed < wall_hacks:
			# Force state back to CHASE so the guard actively pursues the cheat updates
			current_state = State.CHASE
			vision_sensor.last_known_position = player.global_position
		else:
			current_state = State.SEARCH_LOST
			_start_search_lost()
		return

	# 3. SEARCH_LOST is sticky
	if current_state == State.SEARCH_LOST:
		# Only interrupt SEARCH_LOST if a genuinely fresh/loud sound occurs
		if noise_sensor.get_sound_strength() > search_noise_interrupt:
			_reseed_search_from_noise(noise_sensor.get_last_sound_position())
			current_state = State.INVESTIGATE
			return

		var elapsed: float = (Time.get_ticks_msec() / 1000.0) - _search_started_at

		if _has_search_destination and not _solver_pending \
				and global_position.distance_to(_search_destination) < search_arrival_tolerance:
			if elapsed < min_search_duration:
				_continue_search_lost_from(_search_destination)
				return
			
			# Search duration expired and arrived at destination: Clean up and go to patrol
			_reset_search()
			current_state = State.PATROL
			return

		if elapsed < min_search_duration:
			return

		if not _has_search_destination:
			_reset_search()
			current_state = State.PATROL
			return

		return

	# 4. INVESTIGATE is sticky until arrival
	if current_state == State.INVESTIGATE:
		var sound_pos = noise_sensor.get_last_sound_position()
		
		# Flatten vectors to 2D (X and Z) to ignore height differences
		var guard_pos_2d = Vector3(global_position.x, 0, global_position.z)
		var sound_pos_2d = Vector3(sound_pos.x, 0, sound_pos.z)
		var dist_to_sound = guard_pos_2d.distance_to(sound_pos_2d)
		
		# Check BOTH our manual 2D distance AND if the navigation agent thinks it's done
		if dist_to_sound <= investigate_arrival_tolerance or nav_agent.is_navigation_finished():
		# --- FIX: Clear the noise sensor memory so it doesn't re-trigger next frame ---
			if noise_sensor.has_method("clear"):
				noise_sensor.clear()
			else:
				# Fallback if no clear method exists: overwrite it with zero loudness/current pos
				noise_sensor.register_sound(global_position) 
				if "sound_strength" in noise_sensor:
					noise_sensor.sound_strength = 0.0 # Or whatever your sensor uses internally
					
			current_state = State.PATROL
			return
			
		# Bypass the fallback code below to stay committed to this state
		return

	# 5. Initial state change via sound sensors (Fallback capture)
	if noise_sensor.get_sound_strength() > 0.2:
		current_state = State.INVESTIGATE
		return

	# 6. Default
	current_state = State.PATROL


func _execute_state(delta: float):
	match current_state:
		State.PATROL:
			print("Patrol")
			guard_movement.set_state(guard_movement.State.PATROL)

		State.INVESTIGATE:
			print("Investigate")
			guard_movement.set_state(guard_movement.State.INVESTIGATE, noise_sensor.get_last_sound_position())

		State.CHASE:
			print("Chase")
			guard_movement.set_state(guard_movement.State.CHASE, vision_sensor.get_last_known_position())

		State.SHOOT:
			print("Shoot")
			# Keep the guard planted on the ground, rotating continuously to look directly at the player
			guard_movement.set_state(guard_movement.State.DEFAULT, player.global_position)
			
			# Weapon firing cycle
			_fire_timer -= delta
			if _fire_timer <= 0.0:
				_fire_gun()
				_fire_timer = fire_rate # Reset weapon cooldown

		State.SEARCH_LOST:
			print("Seach Lost")
			if _has_search_destination:
				guard_movement.set_state(guard_movement.State.CHASE, _search_destination)


func _fire_gun() -> void:
	print("BANG! Guard fired a hitscan shot.")
	gun_sound_player.play()
	
	# Not every shot should hit
	var rand = randi_range(1,100)
	if rand > 65:
		return
	
	# 1. Calculate the vector pointing from the guard to the player's chest
	var guard_chest = global_position + Vector3(0, 1.2, 0)
	var player_chest = player.global_position + Vector3(0, 1.2, 0)
	
	# 2. Make sure the raycast node itself ignores the guard's own collision capsule
	muzzle_raycast.add_exception(self)
	
	# 3. Position the raycast node at the guard's chest height
	muzzle_raycast.global_position = guard_chest
	
	# 4. CRITICAL FIX: Set the length of the raycast to match the actual distance.
	# We transform the global target vector into the raycast's local space.
	var local_target = muzzle_raycast.to_local(player_chest)
	muzzle_raycast.target_position = local_target
	
	# 5. Force the physics engine to calculate the ray right now
	muzzle_raycast.force_raycast_update()
	
	# 6. Check for hits
	if muzzle_raycast.is_colliding():
		var collider = muzzle_raycast.get_collider()
		print("Raycast hit: ", collider.name)
		
		if collider == player:
			print("Player was HIT!")
			if player.has_method("take_damage"):
				player.take_damage(20)

# =====================================================================
# SEARCH_LOST helpers
# =====================================================================
func _start_search_lost() -> void:
	if _solver_pending or chase_solver.is_solving():
		return
	if not chase_solver.navigation_map.is_valid():
		chase_solver.navigation_map = nav_agent.get_navigation_map()

	# Clear old noises so they don't interrupt us instantly
	if noise_sensor.has_method("clear"):
		noise_sensor.clear()
	elif "sound_strength" in noise_sensor:
		noise_sensor.register_sound(global_position)
		noise_sensor.sound_strength = 0.0

	_solver_pending = true
	_has_search_destination = false
	_search_started_at = Time.get_ticks_msec() / 1000.0

	var last_pos: Vector3 = vision_sensor.get_last_known_position()
	var last_dir: Vector3 = _estimate_player_direction()
	chase_solver.solve(last_pos, last_dir)


func _reseed_search_from_noise(noise_pos: Vector3) -> void:
	if _solver_pending or chase_solver.is_solving():
		return
	if not chase_solver.navigation_map.is_valid():
		chase_solver.navigation_map = nav_agent.get_navigation_map()

	var dir: Vector3 = noise_pos - vision_sensor.get_last_known_position()
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = -global_transform.basis.z

	_solver_pending = true
	_has_search_destination = false

	chase_solver.solve(noise_pos, dir.normalized())


func _continue_search_lost_from(from_pos: Vector3) -> void:
	if _solver_pending or chase_solver.is_solving():
		return
	if not chase_solver.navigation_map.is_valid():
		chase_solver.navigation_map = nav_agent.get_navigation_map()

	_solver_pending = true
	_has_search_destination = false

	var dir: Vector3 = _estimate_player_direction()
	chase_solver.solve(from_pos, dir)


func _estimate_player_direction() -> Vector3:
	if vision_sensor.has_method("get_last_known_velocity"):
		var v: Vector3 = vision_sensor.get_last_known_velocity()
		if v.length_squared() > 0.0001:
			return v.normalized()
	var to_target: Vector3 = vision_sensor.get_last_known_position() - global_position
	to_target.y = 0.0
	if to_target.length_squared() > 0.0001:
		return to_target.normalized()
	return -global_transform.basis.z


func _reset_search() -> void:
	_solver_pending = false
	_has_search_destination = false


func _on_search_destination_ready(dest: Vector3) -> void:
	_solver_pending = false
	_search_destination = dest
	_has_search_destination = true
	print("Solver: destination ready at ", dest, " (dist from guard=%.2f)" % global_position.distance_to(dest))


func _on_search_failed() -> void:
	_solver_pending = false
	_has_search_destination = false
	print("Solver: failed (will fall back after min_search_duration)")
	
func handle_animation():
	animationTree.set("parameters/conditions/dead", false) 
	animationTree.set("parameters/conditions/shooting", current_state == State.SHOOT)
	animationTree.set("parameters/conditions/alerted", current_state == State.INVESTIGATE || current_state == State.SEARCH_LOST)
	animationTree.set("parameters/conditions/chasing", current_state == State.CHASE)
	animationTree.set("parameters/conditions/walking", current_state == State.PATROL)
	
func die():
	if dead:
		return
	state_indicator.queue_free()
	vision_cone.queue_free()
	guard_movement.queue_free()
	state_machine.travel("Death")
	dead = true
	set_targeted(false)
	
func set_targeted(targeted: bool):
	shuriken_indicator.visible = targeted

func investigate_sound(target_position: Vector3):
	noise_sensor.register_sound(target_position)
	# If called while in patrol, it forces the state shift immediately
	if current_state == State.PATROL:
		current_state = State.INVESTIGATE
