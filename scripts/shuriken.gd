extends Area3D

@export var speed: float = 25.0
@export var rotation_speed: float = 20.0

var target_node: Node3D = null
var direction: Vector3 = Vector3.FORWARD

func launch(target: Node3D):
	target_node = target
	# Calculate initial baseline direction pointing at the enemy's center
	if target_node:
		direction = (target_node.global_position + Vector3.UP - global_position).normalized()

func _physics_process(delta):
	if is_instance_valid(target_node):
		# Re-orient slightly toward the target dynamically (Soft Homing)
		var target_dir = (target_node.global_position + Vector3.UP - global_position).normalized()
		direction = direction.lerp(target_dir, delta * 5.0).normalized()
		
		# Rotate the actual shuriken mesh purely for visual spin flavor
		self.rotate_y(rotation_speed * delta)
	
	# Move along our directional vector
	global_position += direction * speed * delta

func _on_body_entered(body):
	if body.is_in_group("Guard"):
		if body.has_method("die"):
			body.die() # Instant lethal kill call
			
	visible = false
