extends CharacterBody3D

# =========================
# STANCE SYSTEM
# =========================
enum Stance {
	STAND,
	CROUCH,
	CRAWL
}

var stance: Stance = Stance.STAND

# =========================
# INPUT TIMING (ONLY FOR CRAWL)
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

var direction

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

# ==================================================
# READY
# ==================================================
func _ready():
	lookat = get_tree().get_nodes_in_group("CameraController")[0].get_node("CameraLookAt")
	animationTree = $hamster_character/AnimationTree
	audioPlayer = $RaytracedAudioPlayer3D
	guards = get_tree().get_nodes_in_group("Guard")
	state_machine = animationTree.get("parameters/playback")

# ==================================================
# INPUT
# ==================================================
func _input(event):
	if event.is_action_pressed("crouch"):
		crouch_pressed = true
		crouch_press_time = 0.0

	if event.is_action_released("crouch"):
		# If we are standing → tap toggles crouch
		if stance == Stance.STAND:
			stance = Stance.CROUCH
		
		# If we are crouching:
		elif stance == Stance.CROUCH:
			# Short tap → stand up
			if crouch_press_time < crawl_hold_threshold:
				stance = Stance.STAND
			# Long hold → enter crawl
			else:
				stance = Stance.CRAWL
		
		# If crawling → tap returns to stand
		elif stance == Stance.CRAWL:
			stance = Stance.CROUCH
		
		crouch_pressed = false

# ==================================================
# PHYSICS LOOP
# ==================================================
func _physics_process(delta):
	# Track hold duration
	if crouch_pressed:
		crouch_press_time += delta
	
	apply_gravity(delta)
	handle_jump()
	handle_shoot()
	
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	sprinting = Input.is_action_pressed("sprint") and stance == Stance.STAND
	
	var speed = get_speed()
	update_noise()
	
	handle_rotation()
	handle_movement(direction, speed)
	update_animation(input_dir)

	if stance == Stance.CRAWL:
		if direction != Vector3.ZERO:
			animationTree.set("parameters/playback_speed", 1.0)
		else:
			animationTree.set("parameters/playback_speed", 0.0)
	else:
		animationTree.set("parameters/playback_speed", 1.0)
	
	if direction != Vector3.ZERO:
		emit_footsteps()
	
	move_and_slide()

# ==================================================
# CORE MECHANICS
# ==================================================
func apply_gravity(delta):
	if not is_on_floor():
		velocity.y -= gravity * delta

func handle_jump():
	if Input.is_action_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

func handle_shoot():
	if Input.is_action_just_pressed("shoot") and is_on_floor():
		var state_machine = animationTree.get("parameters/playback")
		state_machine.travel("Throw")

# ==================================================
# MOVEMENT / NOISE
# ==================================================
func get_speed() -> float:
	match stance:
		Stance.STAND:
			return sprint_speed if sprinting else walk_speed
		Stance.CROUCH:
			return crouch_speed
		Stance.CRAWL:
			return crawl_speed
	return walk_speed

func update_noise():
	match stance:
		Stance.STAND:
			audioPlayer.set_volume_db(sprinting_noise if sprinting else walking_noise)
		Stance.CROUCH:
			audioPlayer.set_volume_db(crouched_noise)
		Stance.CRAWL:
			audioPlayer.set_volume_db(crawling_noise)

# ==================================================
# MOVEMENT HELPERS
# ==================================================
func handle_rotation():
	var target = Vector3(lookat.global_position.x, global_position.y, lookat.global_position.z)
	var lerped = lerp(lastLookAtDirection, target, 0.5)
	look_at(lerped)
	lastLookAtDirection = lerped

func handle_movement(direction: Vector3, speed: float):
	if direction != Vector3.ZERO:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

# ==================================================
# ANIMATION
# ==================================================
func update_animation(input_dir: Vector2):
	var on_floor = is_on_floor()
	
	animationTree.set("parameters/conditions/idle", input_dir == Vector2.ZERO and on_floor)
	animationTree.set("parameters/conditions/falling", not on_floor)
	animationTree.set("parameters/conditions/landed", on_floor)
	
	animationTree.set("parameters/conditions/sprinting", sprinting)
	animationTree.set("parameters/conditions/crouched", stance != Stance.STAND)
	animationTree.set("parameters/conditions/crawling", stance == Stance.CRAWL)
	
	animationTree.set("parameters/conditions/walking", input_dir.y != 0 and on_floor)
	animationTree.set("parameters/Walking/conditions/walking", abs(input_dir.y) == 1 and on_floor)
	animationTree.set("parameters/Walking/conditions/strafeLeft", input_dir.x == -1 and on_floor)
	animationTree.set("parameters/Walking/conditions/strafeRight", input_dir.x == 1 and on_floor)

# ==================================================
# FOOTSTEPS / SOUND
# ==================================================
func emit_footsteps():
	if not audioPlayer.is_playing() and is_on_floor():
		audioPlayer.play()
		
		for g in guards:
			if audioPlayer.get_volume_db_from_pos(g.global_position) > footstep_threshold:
				g.investigate_sound(global_position)
