shader_type spatial;
render_mode unshaded, skip_vertex_transform; // Crucial: we handle transformations manually

// Use these parameters in the Inspector to control the look
uniform vec4 line_color : source_color = vec4(0.0, 1.0, 0.3, 1.0); // Bright Neon Green
uniform float thickness : hint_range(1.0, 30.0) = 8.0;

void vertex() {
	// 1. Transform the standard 3D vertex to Clip Space manually
	vec4 clip_position = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0);
	
	// 2. Transform the normal (direction) to Clip Space
	// This tells us "which way is out" relative to the line at this screen pixel
	vec3 clip_normal = mat3(PROJECTION_MATRIX) * mat3(VIEW_MATRIX) * mat3(MODEL_MATRIX) * NORMAL;
	
	// 3. Calculate the side-offset in pixels
	// By normalizing the 2D xy direction and dividing by screen size
	vec2 offset = normalize(clip_normal.xy) / VIEWPORT_SIZE * thickness * clip_position.w;
	
	// 4. Apply the offset to the final position
	clip_position.xy += offset;
	
	POSITION = clip_position;
}

void fragment() {
	ALBEDO = line_color.rgb;
	ALPHA = line_color.a;
}