extends CharacterBody3D

# =========================
# STANCE SYSTEM
# =========================
enum Stance { STAND, CROUCH, CRAWL }
var stance: Stance = Stance.STAND

# =========================
# INPUT TIMING
# =========================
var crouch_pressed := false
var crouch_press_time := 0.0
@export var crawl_hold_threshold := 0.25

# =========================
# MOVEMENT / NOISE
# =========================
@export var footstep_threshold = 0
@export var crouched_noise = -10
@export var crawling_noise = -20
@export var sprinting_noise = 5
@export var walking_noise = 0

@export var walk_speed = 5.0
@export var sprint_speed = 7.0
@export var crouch_speed = 2.5
@export var crawl_speed = 1.2

@onready var floor_detector: RayCast3D = $FloorDetector

# =========================
# VISIBILITY
# =========================

@onready var sun_light: DirectionalLight3D = $"../SunLight"
@export var base_ambient_light: float = 0.05 # The minimum brightness in total shadow
var light_posts : Array[OmniLight3D] = []
var visibility := 1.0

const JUMP_VELOCITY = 4.5
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")

# =========================
# STATE
# =========================
var sprinting := false
var lastLookAtDirection: Vector3

# =========================
# REFERENCES
# =========================
var lookat
var animationTree
var audioPlayer
var guards = []
var state_machine


# =========================
# THROW OBJECT / PREVIEW
# =========================
var is_aiming := false
var throw_cancelled := false
var throw_strength := 0.0
@export var charge_speed := 1.5 
@export var max_charge := 2.0

# RE-REFERENCE: Make sure the node name matches exactly in your scene tree
@onready var trajectory_line = $TrajectoryLine 

# ==================================================
# READY
# ==================================================
func _ready():
	lookat = get_tree().get_nodes_in_group("CameraController")[0].get_node("CameraLookAt")
	animationTree = $hamster_character/AnimationTree
	audioPlayer = $RaytracedAudioPlayer3D
	guards = get_tree().get_nodes_in_group("Guard")
	state_machine = animationTree.get("parameters/playback")
	
	if trajectory_line:
		# This is the magic line. It makes the line ignore the player's 
		# movement/rotation so (0,0,0) is the world origin.
		trajectory_line.set_as_top_level(true) 
		trajectory_line.hide()
		
		# Ensure the mesh is initialized
		if trajectory_line.mesh == null:
			trajectory_line.mesh = ImmediateMesh.new()
			
func register_local_light(light: Light3D):
	print("Append light")
	light_posts.append(light)

func unregister_local_light(light: Light3D):
	light_posts.erase(light)

# ==================================================
# INPUT
# ==================================================
func _input(event):
	if event.is_action_pressed("crouch"):
		crouch_pressed = true
		crouch_press_time = 0.0

	if event.is_action_released("crouch"):
		if stance == Stance.STAND: stance = Stance.CROUCH
		elif stance == Stance.CROUCH:
			if crouch_press_time < crawl_hold_threshold: stance = Stance.STAND
			else: stance = Stance.CRAWL
		elif stance == Stance.CRAWL: stance = Stance.CROUCH
		crouch_pressed = false
		
	if event.is_action_pressed("shoot"):
		is_aiming = true
		throw_cancelled = false
		throw_strength = 0.0
		if trajectory_line: trajectory_line.show()

	if event.is_action_released("shoot") and is_aiming:
		if not throw_cancelled: release_throw()
		is_aiming = false
		if trajectory_line: trajectory_line.hide()

	if event.is_action_pressed("cancel"): 
		if is_aiming:
			throw_cancelled = true
			is_aiming = false
			if trajectory_line: trajectory_line.hide()

# ==================================================
# PHYSICS LOOP
# ==================================================
func _physics_process(delta):
	if is_aiming:
		throw_strength += charge_speed * delta
		throw_strength = clamp(throw_strength, 0.0, max_charge)
		update_trajectory_preview()
		
	if crouch_pressed:
		crouch_press_time += delta
	
	apply_gravity(delta)
	handle_jump()
	
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	sprinting = Input.is_action_pressed("sprint") and stance == Stance.STAND
	
	handle_rotation()
	handle_movement(direction, get_speed())
	update_animation(input_dir)

	if stance == Stance.CRAWL:
		animationTree.set("parameters/playback_speed", 1.0 if direction != Vector3.ZERO else 0.0)
	else:
		animationTree.set("parameters/playback_speed", 1.0)
	
	if direction != Vector3.ZERO: emit_footsteps()
	visibility = calculate_total_visibility()

	update_noise()
	move_and_slide()
	
	
func calculate_total_visibility() -> float:
	var total_light = base_ambient_light
	var space_state = get_world_3d().direct_space_state
	var ray_origin = global_position + Vector3(0, 1.0, 0) # Adjust based on stance height!

	# --- PROCESS 1: THE SUN ---
	if sun_light:
		var sun_dir = sun_light.global_basis.z.normalized()
		var sun_query = PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + (sun_dir * 500.0))
		sun_query.exclude = [self.get_rid()]
		
		var sun_hit = space_state.intersect_ray(sun_query)
		if !sun_hit:
			# No obstacle between player and sun
			total_light += 1.0 

	# --- PROCESS 2: LOCAL LIGHT POSTS ---
	for light in light_posts:
		var light_query = PhysicsRayQueryParameters3D.create(ray_origin, light.global_position)
		light_query.exclude = [self.get_rid()]
		
		var light_hit = space_state.intersect_ray(light_query)
		if !light_hit:
			# Clear line of sight to the lamp post! Calculate intensity by distance
			var dist = ray_origin.distance_to(light.global_position)
			var max_range = light.get_light_range()
			
			var local_intensity = 1.0 - (dist / max_range)
			total_light += clamp(local_intensity, 0.0, 1.0)

	# Keep the final value within a clean 0.0 - 1.0 UI/AI friendly range
	return clamp(total_light, 0.0, 1.0)

# ==================================================
# TRAJECTORY PREVIEW (FIXED ORIGIN)
# ==================================================
func update_trajectory_preview():
	if not trajectory_line or not trajectory_line.mesh: return
	
	var points = []
	var start_pos = global_position + Vector3.UP * 1.5
	var current_velocity = get_throw_velocity()
	var current_pos = start_pos + Vector3(10,0,10)
	
	var step_delta = 0.05 
	for i in range(40):
		points.append(current_pos)
		current_pos += current_velocity * step_delta
		current_velocity.y -= gravity * step_delta
		
	var mesh: ImmediateMesh = trajectory_line.mesh
	mesh.clear_surfaces()
	
	# We draw the path 3 times with a tiny offset to "thicken" the line
	var offsets = [
		Vector3(0, 0, 0),
		Vector3(0.02, 0.02, 0), 
		Vector3(-0.02, -0.02, 0)
	]
	
	for offset in offsets:
		mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for p in points:
			mesh.surface_add_vertex(p + offset)
		mesh.surface_end()

# ==================================================
# CORE MECHANICS
# ==================================================
func apply_gravity(delta):
	if not is_on_floor(): velocity.y -= gravity * delta

func handle_jump():
	if Input.is_action_just_pressed("jump") and is_on_floor(): velocity.y = JUMP_VELOCITY

func get_speed() -> float:
	match stance:
		Stance.STAND: return sprint_speed if sprinting else walk_speed
		Stance.CROUCH: return crouch_speed
		Stance.CRAWL: return crawl_speed
	return walk_speed

func update_noise():
	var modifier = 1
	if floor_detector.is_colliding():
		var collider = floor_detector.get_collider()
		
		# Check if the collider has our surface metadata attached
		if collider.has_meta("surface_data"):
			var surface: SurfaceProperties = collider.get_meta("surface_data")
			if surface:
				modifier = surface.sound_modifier
				
	print("Modifier, ", modifier)
	var volume
	match stance:
		Stance.STAND: volume = sprinting_noise if sprinting else walking_noise
		Stance.CROUCH: volume = crouched_noise
		Stance.CRAWL: volume = crawling_noise
	volume *= modifier
	audioPlayer.set_volume_db(volume)

func handle_rotation():
	var target = Vector3(lookat.global_position.x, global_position.y, lookat.global_position.z)
	var lerped = lastLookAtDirection.lerp(target, 0.5)
	look_at(lerped)
	lastLookAtDirection = lerped

func handle_movement(direction: Vector3, speed: float):
	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

func update_animation(input_dir: Vector2):
	var on_floor = is_on_floor()
	animationTree.set("parameters/conditions/idle", input_dir == Vector2.ZERO and on_floor)
	animationTree.set("parameters/conditions/falling", not on_floor)
	animationTree.set("parameters/conditions/landed", on_floor)
	animationTree.set("parameters/conditions/sprinting", sprinting)
	animationTree.set("parameters/conditions/crouched", stance != Stance.STAND)
	animationTree.set("parameters/conditions/crawling", stance == Stance.CRAWL)
	animationTree.set("parameters/conditions/walking", input_dir.y != 0 and on_floor)
	animationTree.set("parameters/Walking/conditions/strafeLeft", input_dir.x == -1.0 && is_on_floor())
	animationTree.set("parameters/Walking/conditions/strafeRight", input_dir.x == 1.0 && is_on_floor())

func release_throw():
	spawn_projectile()

func get_throw_velocity() -> Vector3:
	var forward = -global_transform.basis.z
	var strength = lerp(7.0, 20.0, throw_strength / max_charge)
	return forward * strength + Vector3.UP * 3.0

func spawn_projectile():
	var projectile_scene = load("res://scenes/throw_object.tscn")
	if projectile_scene:
		var projectile = projectile_scene.instantiate()
		get_tree().current_scene.add_child(projectile)
		projectile.global_position = global_position + Vector3.UP * 1.5
		projectile.linear_velocity = get_throw_velocity()

func emit_footsteps():
	if not audioPlayer.is_playing() and is_on_floor():
		audioPlayer.play()
		for g in guards:
			if audioPlayer.get_volume_db_from_pos(g.global_position) > footstep_threshold:
				g.investigate_sound(global_position)
				
				
func get_visibility():
	return visibility
