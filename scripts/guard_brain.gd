extends CharacterBody3D

@onready var noise_sensor: Node3D = $NoiseSensor
@onready var vision_sensor: Node3D = $VisionSensor
@onready var guard_movement: Node3D = $GuardMovement
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
@onready var chase_solver: ChaseInfluenceMap = $ChaseInfluenceMap
@onready var state_indicator: Label3D = $StateIndicator
@onready var vision_cone: MeshInstance3D = $VisionCone
@onready var shuriken_indicator: Sprite3D = $ShurikenIndicator

var animationTree
var state_machine

var dead: bool = false

enum State {
	PATROL,
	INVESTIGATE,
	CHASE,
	SEARCH_LOST    # Pursuing the player after losing sight, using the influence-map flood
}

var current_state: State = State.PATROL
var previous_state: State = State.PATROL

# --- SEARCH_LOST tracking ---
var _search_destination: Vector3 = Vector3.ZERO
var _has_search_destination: bool = false
var _solver_pending: bool = false
var _search_started_at: float = 0.0

# How close the guard must be to its search destination to consider the search done
@export var search_arrival_tolerance: float = 1.0
# A noise this loud will interrupt SEARCH_LOST and switch to INVESTIGATE.
# Default is 1.5, which is ABOVE the noise sensor's max_strength (1.0), so by
# default the player's own footsteps can't derail the search — they'd just
# reinforce it. Lower this only if you want a *distinct* loud stimulus
# (e.g. explosion, gunshot) to redirect the guard.
@export var search_noise_interrupt: float = 1.5
# Minimum time to commit to SEARCH_LOST before any exit path is allowed.
# This includes the noise-interrupt check, so the search visual always plays.
@export var min_search_duration: float = 5.0


func _ready() -> void:
	# Defer one physics frame so the navigation map is fully synced.
	# Otherwise navigation_map can be invalid and the solver fails immediately.
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
	_execute_state()
	handle_animation()


func _update_state():
	previous_state = current_state

	# 1. Vision overrides everything (PRESERVED — original behavior)
	if vision_sensor.get_detection_strength() >= 1.0:
		# If we were searching, abandon it: we've reacquired the target
		if current_state == State.SEARCH_LOST:
			_reset_search()
		current_state = State.CHASE
		#print("Chase")
		return

	# 2. NEW: just lost sight after being in CHASE — start the influence-map flood.
	#    IMPORTANT: set current_state BEFORE calling solve() because solve() can
	#    emit chase_failed synchronously and _on_search_failed checks current_state.
	if current_state == State.CHASE:
		current_state = State.SEARCH_LOST
		_start_search_lost()
		#print("SearchLost (computing)")
		return

	# 3. NEW: SEARCH_LOST is sticky — don't let sensor logic overwrite it
	#    until the destination is reached, the solver fails, or a loud noise interrupts.
	if current_state == State.SEARCH_LOST:
		# Loud noise during SEARCH_LOST: stay in SEARCH_LOST but feed the noise
		# position into the solver as a fresh seed. The noise tells us where
		# the player likely is right now — that's better information than the
		# old last-known-from-vision spot.
		if noise_sensor.get_sound_strength() > search_noise_interrupt:
			#print("SearchLost: noise heard, re-seeding search from sound position")
			_reseed_search_from_noise(noise_sensor.get_last_sound_position())
			return

		var elapsed: float = (Time.get_ticks_msec() / 1000.0) - _search_started_at

		# Arrived at destination:
		# - within commitment window → re-flood from this spot so the search
		#   keeps moving instead of standing still.
		# - past commitment window → fall back.
		if _has_search_destination and not _solver_pending \
				and global_position.distance_to(_search_destination) < search_arrival_tolerance:
			if elapsed < min_search_duration:
				#print("SearchLost: arrived during commitment (t=%.2f), re-flooding" % elapsed)
				_continue_search_lost_from(_search_destination)
				return
			#print("SearchLost: arrived at destination, falling back")
			_reset_search()
			if noise_sensor.get_sound_strength() > 0.2:
				current_state = State.INVESTIGATE
			else:
				current_state = State.PATROL
			return

		# No destination yet — stay committed until the solver delivers one or
		# the commitment window expires.
		if elapsed < min_search_duration:
			#print("SearchLost (committed, t=%.2f)" % elapsed)
			return

		# Past commitment with no destination = solver gave up; fall back.
		if not _has_search_destination:
			#print("SearchLost: no destination after min duration, falling back")
			_reset_search()
			if noise_sensor.get_sound_strength() > 0.2:
				current_state = State.INVESTIGATE
			else:
				current_state = State.PATROL
			return

		# Heading to destination; keep going.
		#print("SearchLost (running, dist=%.2f)" % global_position.distance_to(_search_destination))
		return

	# 4. Sound if no vision (PRESERVED — original behavior)
	if noise_sensor.get_sound_strength() > 0.2:
		current_state = State.INVESTIGATE
		#print("Investigate")
		return

	# 5. Default (PRESERVED — original behavior)
	#print("Patrol")
	current_state = State.PATROL
	


func _execute_state():
	match current_state:
		State.PATROL:
			guard_movement.set_state(guard_movement.State.PATROL)

		State.INVESTIGATE:
			guard_movement.set_state(guard_movement.State.INVESTIGATE, noise_sensor.get_last_sound_position())

		State.CHASE:
			guard_movement.set_state(guard_movement.State.CHASE, vision_sensor.get_last_known_position())

		State.SEARCH_LOST:
			# While the solver is still computing we don't issue a new movement
			# command — the guard keeps moving toward the player's last-known
			# position from the previous CHASE frame. Once the solver delivers a
			# centroid, route through the existing CHASE movement state with the
			# new target so guard_movement doesn't need to know about SEARCH_LOST.
			if _has_search_destination:
				guard_movement.set_state(guard_movement.State.CHASE, _search_destination)


# =====================================================================
# SEARCH_LOST helpers
# =====================================================================
func _start_search_lost() -> void:
	if _solver_pending or chase_solver.is_solving():
		return
	# Refresh the nav map RID in case the world wasn't ready at _ready time.
	if not chase_solver.navigation_map.is_valid():
		chase_solver.navigation_map = nav_agent.get_navigation_map()

	_solver_pending = true
	_has_search_destination = false
	_search_started_at = Time.get_ticks_msec() / 1000.0

	var last_pos: Vector3 = vision_sensor.get_last_known_position()
	var last_dir: Vector3 = _estimate_player_direction()
	print("Solver: starting (seed=", last_pos, ", dir=", last_dir, ")")
	chase_solver.solve(last_pos, last_dir)


# Re-seed the search from a noise position. Resets the commitment timer so
# the guard searches the new area for the full min_search_duration.
func _reseed_search_from_noise(noise_pos: Vector3) -> void:
	if _solver_pending or chase_solver.is_solving():
		return
	if not chase_solver.navigation_map.is_valid():
		chase_solver.navigation_map = nav_agent.get_navigation_map()

	# Direction = where the player apparently moved (old last-known → noise).
	var dir: Vector3 = noise_pos - vision_sensor.get_last_known_position()
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = -global_transform.basis.z

	_solver_pending = true
	_has_search_destination = false
	_search_started_at = Time.get_ticks_msec() / 1000.0  # fresh commitment

	print("Solver: re-seeded from noise (seed=", noise_pos, ", dir=", dir.normalized(), ")")
	chase_solver.solve(noise_pos, dir.normalized())


# Re-flood from the position the guard just reached. Keeps _search_started_at
# unchanged so the commitment timer keeps running.
func _continue_search_lost_from(from_pos: Vector3) -> void:
	if _solver_pending or chase_solver.is_solving():
		return
	if not chase_solver.navigation_map.is_valid():
		chase_solver.navigation_map = nav_agent.get_navigation_map()

	_solver_pending = true
	_has_search_destination = false
	# NB: do NOT reset _search_started_at — commitment timer is preserved.

	var dir: Vector3 = _estimate_player_direction()
	print("Solver: re-flood (seed=", from_pos, ", dir=", dir, ")")
	chase_solver.solve(from_pos, dir)


func _estimate_player_direction() -> Vector3:
	# Prefer the velocity tracked by the vision sensor; fall back to the
	# direction from the guard to the last-known player position; final
	# fallback is the guard's facing direction.
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
	# Don't force-change current_state here — the sticky check in _update_state
	# enforces min_search_duration first, then falls back. Otherwise we'd skip
	# the search visual entirely whenever the solver fails.
	
func handle_animation():
	animationTree.set("parameters/conditions/dead", false)
	animationTree.set("parameters/conditions/shooting", false)
	animationTree.set("parameters/conditions/alerted", current_state == State.INVESTIGATE || current_state == State.SEARCH_LOST)
	animationTree.set("parameters/conditions/chasing", current_state == State.CHASE)
	animationTree.set("parameters/conditions/walking", current_state == State.PATROL)
	
func die():
	state_indicator.visible = false
	vision_cone.visible = false
	guard_movement.set_state(guard_movement.State.DEAD)
	state_machine.travel("Death")
	dead = true
	set_targeted(false)
	
func set_targeted(targeted: bool):
	shuriken_indicator.visible = targeted


# =====================================================================
# External API (PRESERVED)
# =====================================================================
func investigate_sound(target_position: Vector3):
	noise_sensor.register_sound(target_position)
