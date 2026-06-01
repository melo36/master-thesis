extends RigidBody3D

@onready var raytraced_audio_player_3d: RaytracedAudioPlayer3D = $RaytracedAudioPlayer3D
var guards = []

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	guards = get_tree().get_nodes_in_group("Guard")

func _on_body_entered(body):
	print("Collided with ", body.name)
	raytraced_audio_player_3d.play()
	for g in guards:
			if raytraced_audio_player_3d.get_volume_db_from_pos(g.global_position) > 0:
				g.investigate_sound(global_position)
