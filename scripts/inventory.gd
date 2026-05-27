extends Node3D

# 1. Define your custom signals
signal shuriken_changed(new_amount: int)
signal bells_changed(new_amount: int)

# 2. Use setters to automatically emit signals when values change
@export var shuriken: int = 3:
	set(value):
		shuriken = value
		shuriken_changed.emit(shuriken) # Emit the signal

@export var bells: int = 3:
	set(value):
		bells = value
		bells_changed.emit(bells) # Emit the signal

@onready var shuriken_label: Label = $"../CanvasLayer/ShurikenUI/ShurikenLabel"
@onready var bell_label: Label = $"../CanvasLayer/BellUI/BellLabel"

func _ready() -> void:
	# 3. Connect the signals to the update functions
	shuriken_changed.connect(_on_shuriken_changed)
	bells_changed.connect(_on_bells_changed)
	
	# Initialize the UI text on startup
	_on_shuriken_changed(shuriken)
	_on_bells_changed(bells)

# 4. Create the receiver functions to update the text
func _on_shuriken_changed(new_amount: int) -> void:
	shuriken_label.text = str(new_amount)

func _on_bells_changed(new_amount: int) -> void:
	bell_label.text = str(new_amount)
