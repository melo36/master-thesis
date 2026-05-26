shader_type canvas_item;

// This exposes a color picker in the Inspector under "Shader Parameters"
uniform vec4 my_color : source_color = vec4(1.0); 

void fragment() {
    vec4 tex_color = texture(TEXTURE, UV);
    COLOR = tex_color * my_color;
}