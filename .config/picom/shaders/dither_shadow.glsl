#version 330
in vec2 texcoord;
uniform sampler2D tex;
uniform float opacity;
out vec4 fragColor;

// Draw a dithered inner shadow band along the inside edges.
uniform float band_px        = 18.0;   // thickness of inner band (px)
uniform float spread_px      = 22.0;   // how far the band fades inward
uniform float corner_px      = 10.0;   // rounded corner
uniform float max_alpha      = 0.55;   // darkness of the band
uniform vec3  shadow_rgb     = vec3(0.0);
uniform float dither_strength= 1.0;
uniform float alpha_bias     = 0.0;

float bayer8(vec2 p){
    ivec2 ip = ivec2(mod(p,8.0));
    int x=ip.x,y=ip.y;
    int m[64]=int[64](
         0,48,12,60, 3,51,15,63,
        32,16,44,28,35,19,47,31,
         8,56, 4,52,11,59, 7,55,
        40,24,36,20,43,27,39,23,
         2,50,14,62, 1,49,13,61,
        34,18,46,30,33,17,45,29,
        10,58, 6,54, 9,57, 5,53,
        42,26,38,22,41,25,37,21
    );
    return float(m[y*8+x])/64.0;
}

void main(){
    vec4 src = texture(tex, texcoord);
    vec2 texSize = vec2(textureSize(tex,0));
    vec2 px = texcoord * texSize;

    // Distance to inner rect edge (0 at edge, grows inward)
    vec2 innerMin = vec2(band_px);
    vec2 innerMax = texSize - vec2(band_px);
    vec2 dxy = max(innerMin - px, px - innerMax);
    vec2 dpos = max(dxy, 0.0);
    float dist_edge = length(dpos);

    // Rounded corners: subtract radius
    float dist_rounded = max(dist_edge - corner_px, 0.0);

    // Build inner-band falloff (fade toward window center)
    float t = clamp(dist_rounded / max(spread_px,1.0), 0.0, 1.0);
    float a = max_alpha * (1.0 - t);

    // Only apply inside the band region
    float inside_band =
        step(0.0, dist_edge) * // we’re past the edge line
        step(dist_edge, band_px + spread_px + corner_px);

    if (inside_band > 0.5 && a > 0.0) {
        float thresh = mix(0.5, bayer8(gl_FragCoord.xy) + alpha_bias,
                           clamp(dither_strength,0.0,1.0));
        a = (a > thresh) ? 1.0 : 0.0;

        // Composite over content
        vec3 rgb = mix(src.rgb, shadow_rgb, a);
        fragColor = vec4(rgb, max(src.a*opacity, a));
    } else {
        fragColor = vec4(src.rgb, src.a*opacity);
    }
}
