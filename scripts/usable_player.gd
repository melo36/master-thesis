extends CharacterBody3D


@export
var footstep_threshold = 0
@export
var crouched_noise = -10
var speed = 5.0
const JUMP_VELOCITY = 4.5

# Get the gravity from the project settings to be synced with RigidBody nodes.
var gravity = ProjectSettings.get_setting("physics/3d/default_gravity")
var lookat
var lastLookAtDirection : Vector3
var isCrouched : bool

var animationTree
var audioPlayer

var guards = []

func _ready():
	lookat = get_tree().get_nodes_in_group("CameraController")[0].get_node("CameraLookAt")
	isCrouched = false
	animationTree = $hamster_character/AnimationTree
	audioPlayer = $RaytracedAudioPlayer3D
	
	guards = get_tree().get_nodes_in_group("Guard")
	


func _physics_process(delta):
	# Add the gravity.
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Handle Jump.
	if Input.is_action_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	
	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir = Input.get_vector("left", "right", "forward", "backward")
	var direction = (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	
	if Input.is_action_just_pressed("crouch"):
		isCrouched = !isCrouched
		audioPlayer.set_volume_db(crouched_noise)
		if isCrouched:
			speed = 2
		else:
			speed = 5
		
	if direction:
		var lerpDirection = lerp(lastLookAtDirection, Vector3(lookat.global_position.x, global_position.y, lookat.global_position.z), .5)
		look_at(Vector3(lerpDirection.x, global_position.y, lerpDirection.z))
		lastLookAtDirection = lerpDirection
		
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
	
	animationTree.set("parameters/conditions/idle", input_dir == Vector2.ZERO && is_on_floor())
	animationTree.set("parameters/conditions/crouched", is_on_floor() && isCrouched)
	animationTree.set("parameters/conditions/walking", (input_dir.y != 0) && is_on_floor())
	animationTree.set("parameters/Walking/conditions/walking", (input_dir.y == 1.0 || input_dir.y == -1) && is_on_floor())
	animationTree.set("parameters/Walking/conditions/strafeLeft", input_dir.x == -1.0 && is_on_floor())
	animationTree.set("parameters/Walking/conditions/strafeRight", input_dir.x == 1.0 && is_on_floor())
	animationTree.set("parameters/conditions/falling", !is_on_floor())
	animationTree.set("parameters/conditions/landed", is_on_floor())
	
	if (direction):
		emit_footsteps()
		
	move_and_slide()
	
	
func emit_footsteps():
	if(!audioPlayer.is_playing() && is_on_floor()):
		audioPlayer.play()
		
		for x in guards:
			if audioPlayer.get_volume_db_from_pos(x.global_position) > footstep_threshold:
				x.investigate_sound(self.global_position)
	
	
