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
	move_and_slide()

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
	match stance:
		Stance.STAND: audioPlayer.set_volume_db(sprinting_noise if sprinting else walking_noise)
		Stance.CROUCH: audioPlayer.set_volume_db(crouched_noise)
		Stance.CRAWL: audioPlayer.set_volume_db(crawling_noise)

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
