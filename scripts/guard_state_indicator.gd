extends Label3D
# Floating "!" above the guard. Color/opacity reflect the brain's current state:
#   - CHASE / SEARCH_LOST → red (solid)
#   - INVESTIGATE         → yellow (solid)
#   - otherwise (PATROL)  → white, alpha = vision detection strength

@export var color_chase: Color = Color(1.0, 0.15, 0.15)
@export var color_investigate: Color = Color(1.0, 0.9, 0.15)
@export var color_detecting: Color = Color(1.0, 1.0, 1.0)

@onready var brain: Node = get_parent()
@onready var vision: Node = brain.get_node("VisionSensor")


func _process(_delta: float) -> void:
	var s: int = brain.current_state
	if s == brain.State.CHASE or s == brain.State.SEARCH_LOST:
		modulate = color_chase
		visible = true
	elif s == brain.State.INVESTIGATE:
		modulate = color_investigate
		visible = true
	else:
		var det: float = vision.get_detection_strength()
		var c: Color = color_detecting
		c.a = det
		modulate = c
		visible = det > 0.01
