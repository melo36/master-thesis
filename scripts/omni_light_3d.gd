# Inside your LightPost script (attached to an OmniLight3D or SpotLight3D)
extends OmniLight3D

@onready var area: Area3D = $Area3D

func _ready():
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)

func _on_body_entered(body):
	if body.has_method("register_local_light"):
		body.register_local_light(self)

func _on_body_exited(body):
	if body.has_method("unregister_local_light"):
		body.unregister_local_light(self)
		
func get_light_range() -> float:
	# Helper to let the player know how far this light reaches
	return $Area3D/CollisionShape3D.shape.radius
