shader_type canvas_item;

uniform float perspective : hint_range(0.0, 0.35) = 0.0;
uniform float direction = 1.0;

void fragment() {
    float far_edge_weight = direction >= 0.0
        ? UV.x
        : (1.0 - UV.x);

    float cut = perspective * far_edge_weight;

    if (UV.y < cut || UV.y > 1.0 - cut) {
        COLOR = vec4(0.0);
    } else {
        vec2 warped_uv = UV;
        warped_uv.y = (UV.y - cut) / (1.0 - 2.0 * cut);
        COLOR = texture(TEXTURE, warped_uv) * COLOR;
    }
}
