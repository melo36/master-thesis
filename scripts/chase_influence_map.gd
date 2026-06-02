# chase_influence_map.gd
# Influence-map flooding chase algorithm.
# Based on "Flooding the Influence Map for Chase in Dishonored 2"
# by Laurent Couvidou (Game AI Pro Online Edition 2021).
#
# This Node is intended to live as a child of a guard / NPC node.
# Set `navigation_map` (the RID returned by get_world_3d().navigation_map)
# from the parent's _ready(), then call `solve(last_known_pos, last_known_dir)`
# and listen for the `chase_destination_ready(dest)` signal.

extends Node
class_name ChaseInfluenceMap

signal chase_destination_ready(destination: Vector3)
signal chase_failed()  # solver couldn't produce a useful destination

# --- Tunables (paper defaults) ---
@export var hot_value: int = 20             # H
@export var max_heated_per_step: int = 25   # M_H
@export var max_steps: int = 30             # M_S (paper used 20/30/40 per difficulty)
@export var cell_size: float = 0.75         # world units per grid cell
@export var steps_per_frame: int = 2        # spread the flood across frames
@export var build_radius: float = 25.0      # only sample cells within this of the seed
@export var vertical_band: int = 3          # how many cells up/down to sample

# --- Externally provided ---
var navigation_map: RID

# --- Cell storage (sparse, keyed by Vector3i grid coord) ---
var _cell_pos: Dictionary = {}            # Vector3i -> Vector3 (snapped onto navmesh)
var _cell_temp: Dictionary = {}           # Vector3i -> int  (0 cold, >0 warm, -1 barrier)
var _cell_last_heated: Dictionary = {}    # Vector3i -> int step
var _cell_neighbors: Dictionary = {}      # Vector3i -> Array[Vector3i]

# --- Solver state ---
var _heat_front: Array = []
var _barrier_front: Array = []
var _warm_cells: Array = []
var _step: int = 0
var _dir_flat: Vector3 = Vector3.ZERO
var _solving: bool = false

# 8-connected horizontal grid. Vertical connections (stairs, ramps) are
# discovered automatically during neighbor wiring — see _build_local_grid.
const HORIZONTAL_OFFSETS: Array = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(1, 0, 1), Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1), Vector3i(-1, 0, -1),
]
# Y-step deltas a neighbor can be at (handles stairs/ramps within ±2 cells).
const VERTICAL_NEIGHBOR_DELTAS: Array = [0, 1, -1, 2, -2]


# =====================================================================
# PUBLIC API
# =====================================================================
func solve(last_known_pos: Vector3, last_known_dir: Vector3) -> void:
	if _solving:
		#print("ChaseInfluenceMap: solve() called while already solving — ignoring")
		return
	if not navigation_map.is_valid():
		#print("ChaseInfluenceMap: navigation_map RID is invalid — emitting chase_failed")
		chase_failed.emit()
		return
	_solving = true
	_build_local_grid(last_known_pos)
	#print("ChaseInfluenceMap: built grid with %d cells" % _cell_pos.size())
	_seed(last_known_pos, last_known_dir)
	set_process(true)


func is_solving() -> bool:
	return _solving


# =====================================================================
# STEP 1 — Build a sparse 3D cell graph from the navmesh, around the seed
# =====================================================================
func _build_local_grid(seed_pos: Vector3) -> void:
	_cell_pos.clear()
	_cell_temp.clear()
	_cell_last_heated.clear()
	_cell_neighbors.clear()

	var origin: Vector3i = _world_to_grid(seed_pos)
	var radius_cells: int = int(ceil(build_radius / cell_size))

	# Sample ONE cell per (X, Z) column at the seed's Y. The cell's grid Y is
	# set from the navmesh point's actual Y so stairs/ramps connect correctly.
	# Horizontal (XZ) tolerance only — the navmesh typically sits on the floor
	# while the seed (player position) is at chest height.
	for dx in range(-radius_cells, radius_cells + 1):
		for dz in range(-radius_cells, radius_cells + 1):
			var probe: Vector3 = Vector3(
				float(origin.x + dx) * cell_size,
				seed_pos.y,
				float(origin.z + dz) * cell_size
			)
			var nav_pt: Vector3 = NavigationServer3D.map_get_closest_point(navigation_map, probe)
			if abs(nav_pt.x - probe.x) > cell_size * 0.5:
				continue
			if abs(nav_pt.z - probe.z) > cell_size * 0.5:
				continue
			# Don't span across very different floors when sampling a single column
			if abs(nav_pt.y - seed_pos.y) > cell_size * (vertical_band + 0.5):
				continue
			var nav_grid_y: int = int(round(nav_pt.y / cell_size))
			var grid: Vector3i = Vector3i(origin.x + dx, nav_grid_y, origin.z + dz)
			if not _cell_pos.has(grid):
				_cell_pos[grid] = nav_pt
				_cell_temp[grid] = 0
				_cell_last_heated[grid] = -1
				_cell_neighbors[grid] = []

	# Wire neighbors. For each horizontal direction, try the same Y first and
	# then ±1, ±2 cell heights so stairs and ramps connect.
	for grid in _cell_pos.keys():
		for h_off in HORIZONTAL_OFFSETS:
			for y_off in VERTICAL_NEIGHBOR_DELTAS:
				var n: Vector3i = grid + h_off + Vector3i(0, y_off, 0)
				if _cell_pos.has(n):
					_cell_neighbors[grid].append(n)
					break  # take the closest-Y match only


# =====================================================================
# STEP 2 — Seed the influence map (paper Step A)
# =====================================================================
func _seed(last_known_pos: Vector3, last_known_dir: Vector3) -> void:
	_heat_front.clear()
	_barrier_front.clear()
	_warm_cells.clear()
	_step = 0

	_dir_flat = Vector3(last_known_dir.x, 0.0, last_known_dir.z)
	if _dir_flat.length_squared() > 0.0001:
		_dir_flat = _dir_flat.normalized()
	else:
		_dir_flat = Vector3.FORWARD  # fallback if direction unknown

	var seed_grid: Vector3i = _closest_cell(last_known_pos)
	if not _cell_pos.has(seed_grid):
		#print("ChaseInfluenceMap: no navmesh cell near last-known position ", last_known_pos)
		_solving = false
		set_process(false)
		chase_failed.emit()
		return

	# (1) Heat seed
	_cell_temp[seed_grid] = hot_value
	_cell_last_heated[seed_grid] = 0
	_heat_front.append(seed_grid)
	_warm_cells.append(seed_grid)

	# (2) Barrier seed: neighbors in the half-plane behind the player's motion
	var seed_pos: Vector3 = _cell_pos[seed_grid]
	for n in _cell_neighbors[seed_grid]:
		if _is_behind(seed_pos, _cell_pos[n]):
			_cell_temp[n] = -1
			_barrier_front.append(n)


# =====================================================================
# STEP 3 — Propagate (paper Step B), N steps per frame
# =====================================================================
func _process(_delta: float) -> void:
	if not _solving:
		return
	for i in steps_per_frame:
		if not _propagate_one_step():
			_finish()
			return


func _propagate_one_step() -> bool:
	_step += 1

	# Phase 1 — heat propagation
	var next_heat: Array = []
	for grid in _heat_front:
		for n in _cell_neighbors[grid]:
			if _cell_temp[n] == 0:  # untouched (not warm, not barrier)
				_cell_temp[n] = hot_value
				_cell_last_heated[n] = _step
				next_heat.append(n)
				_warm_cells.append(n)

	# Cool down warm cells that were not (re-)heated this step
	for grid in _warm_cells:
		if _cell_last_heated[grid] < _step and _cell_temp[grid] > 0:
			_cell_temp[grid] -= 1

	# Phase 2 — barrier propagation, only into the same back-half-plane
	var next_barrier: Array = []
	for b in _barrier_front:
		var b_pos: Vector3 = _cell_pos[b]
		for n in _cell_neighbors[b]:
			if _cell_temp[n] != -1 and _is_behind(b_pos, _cell_pos[n]):
				_cell_temp[n] = -1
				next_barrier.append(n)

	_heat_front = next_heat
	_barrier_front = next_barrier

	# Stop conditions (paper §3)
	if _heat_front.is_empty():
		return false                       # no further cells to heat
	if _heat_front.size() > max_heated_per_step:
		return false                       # opened into a wide area — give up
	if _step >= max_steps:
		return false                       # difficulty cap reached
	return true


# =====================================================================
# STEP 4 — Compute weighted centroid of warm cells, snap to navmesh
# =====================================================================
func _finish() -> void:
	set_process(false)
	_solving = false

	var sum_pos: Vector3 = Vector3.ZERO
	var sum_w: float = 0.0
	for grid in _warm_cells:
		var t: int = _cell_temp[grid]
		if t > 0:
			sum_pos += _cell_pos[grid] * float(t)
			sum_w += float(t)

	if sum_w <= 0.0:
		#print("ChaseInfluenceMap: no warm cells at finish — emitting chase_failed")
		chase_failed.emit()
		return

	var centroid: Vector3 = sum_pos / sum_w
	var dest: Vector3 = NavigationServer3D.map_get_closest_point(navigation_map, centroid)
	#print("ChaseInfluenceMap: finished after %d steps, %d warm cells, centroid=%s" % [_step, _warm_cells.size(), str(centroid)])
	chase_destination_ready.emit(dest)


# =====================================================================
# Helpers
# =====================================================================
func _is_behind(origin: Vector3, target: Vector3) -> bool:
	var off: Vector3 = target - origin
	var off_flat: Vector3 = Vector3(off.x, 0.0, off.z)
	return off_flat.dot(_dir_flat) < 0.0


func _world_to_grid(p: Vector3) -> Vector3i:
	return Vector3i(
		int(round(p.x / cell_size)),
		int(round(p.y / cell_size)),
		int(round(p.z / cell_size))
	)


func _grid_to_world(g: Vector3i) -> Vector3:
	return Vector3(g.x, g.y, g.z) * cell_size


func _closest_cell(p: Vector3) -> Vector3i:
	var g: Vector3i = _world_to_grid(p)
	if _cell_pos.has(g):
		return g
	for r in range(1, 4):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				for dz in range(-r, r + 1):
					var c: Vector3i = g + Vector3i(dx, dy, dz)
					if _cell_pos.has(c):
						return c
	return Vector3i.ZERO
