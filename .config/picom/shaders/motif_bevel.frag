#version 330

// Picom shader interface (mirrors ikz87 repo)
in vec2 texcoord;                 // pixel-space coords
uniform float opacity;            // window opacity (0..1)
uniform float corner_radius;      // rounded corner radius (pixels)
uniform sampler2D tex;            // window texture

// --- Tweakables (with sane defaults you can override from picom rules) ---

const float border_width = 5.0; // Should match WM

// Thickness of the cut orthogonal to the edge
const int relief_thickness = 1;

int relief_offset = 30;//max(min(window_size.x,window_size.y) * 0.03,5);
// How far the L cut is offset *from the actual corner*


// How far the L extends *along the edge* inside the border
const float relief_length = 6.0;
// Motif palette
uniform vec3  tone = vec3(1.0,0.4,0.9);
vec3  lightC    = mix(tone,vec3(0.75, 0.75, 0.78),0.8);
vec3  darkC     = mix(tone,vec3(0.25, 0.25, 0.20),0.8);
uniform vec3 relief_rgb = vec3(0.00, 0.00, 0.00);


const float OUTER_BAND_PX = 2.0;  // thin rim at the very outside
const float INNER_BAND_PX = 1.0;  // thin rim at the inner edge (next to content)

// Default post-processing from the repo
vec4 default_post_processing(vec4 c);

// Window size (pixel-space)
ivec2 window_size = textureSize(tex, 0);

// ---- helpers (from the repo, unchanged) ----

// Define useful functios
bool corner(bool left, bool top, float cx, float cy) {
    return (
        ((left   && texcoord.x < cx) || (!left && texcoord.x > cx))
        && ((top && texcoord.y < cy) || (!top  && texcoord.y > cy))
        && pow(cx-texcoord.x, 2)
            + pow(cy-texcoord.y, 2)
            > pow(corner_radius-border_width, 2)
    );
}

// ---- our utilities ----
float clamp01(float x){ return clamp(x, 0.0, 1.0); }
vec3  lerp3(vec3 a, vec3 b, float t){ return a + t*(b - a); }
float qpx(float d) { return floor(d + 0.5); }

bool in_relief(ivec2 pixel, ivec2 window, float offset)
{
    int x = pixel.x;
    int y = pixel.y;
    int b = int(border_width);
    int ox = (window.x-x);
    int oy = (window.y-y);

    bool TL = (
        ( abs(y-offset) < relief_thickness));

    bool TR = (
        (abs(x-offset) < relief_thickness));

    bool BL = (
        (abs(oy-offset) < relief_thickness));

    bool BR = (
        (abs(ox-offset) < relief_thickness));

    return TL || TR || BL || BR;
}

// --- Drop-in relief mask (1 px thick everywhere) ---
// Uses: texcoord (0..1), window_size (pixels), border_width (pixels)
// Define an integer offset (in pixels) from the outer corner along each edge.



bool in_border(vec2 pixel, vec2 window, float b) {
  float x = pixel.x;
  float y = pixel.y;
  float w = window.x;
  float h = window.y;
  return x < b
      || y < b
      || x > w - b
      || y > h - b;
}


// vec3 bevel_color(float b)
// {

//     // ---- Tunables (per-edge band thickness) ----
//     // Use *pixel* units if your distances are in pixels, or the same units as your border math.
//     // Keep them const as uniforms can be flaky across some picom builds.

//     // Guard against tiny borders and overlapping bands
//     float outerN = OUTER_BAND_PX / max(b, 0.0001);
//     float innerN = INNER_BAND_PX / max(b, 0.0001);
//     float totalN = outerN + innerN;
//     if (totalN > 0.9) { // scale down if bands would swallow the whole border
//         outerN *= 0.9 / totalN;
//         innerN *= 0.9 / totalN;
//     }

//     // Distances to each edge (same as before)
//     float dl = texcoord.x;
//     float dr = window_size.x - texcoord.x;
//     float dt = texcoord.y;
//     float db = window_size.y - texcoord.y;

//     // Nearest edge decides which side this pixel belongs to
//     float m = min(min(dl, dr), min(dt, db));

//     // Normalized thickness coordinate t: 0 at outer edge, 1 at inner edge
//     float t;

//     // For stepped look we’ll use three zones:
//     // [0, outerN) => "outer band" color
//     // [outerN, 1 - innerN) => "middle fill" color
//     // [1 - innerN, 1] => "inner band" color
//     //
//     // Polarity:
//     //  - TOP/LEFT: outer = light, inner = dark  (classic raised look at top/left)
//     //  - BOTTOM/RIGHT: outer = dark, inner = light
//     vec3 outerCol, midCol, innerCol;

//     if (m == dl) {
//         // LEFT: light (outer) -> mid -> dark (inner)
//         t        = clamp01(dl / b);
//         outerCol = lightC;
//         innerCol = darkC;
//     } else if (m == dt) {
//         // TOP: light (outer) -> mid -> dark (inner)
//         t        = clamp01(dt / b);
//         outerCol = lightC;
//         innerCol = darkC;
//     } else if (m == dr) {
//         // RIGHT: dark (outer) -> mid -> light (inner)
//         t        = clamp01(dr / b);
//         outerCol = darkC;
//         innerCol = lightC;
//     } else {
//         // BOTTOM: dark (outer) -> mid -> light (inner)
//         t        = clamp(db / b, 0.0, 1.0);
//         outerCol = darkC;
//         innerCol = lightC;
//     }

//     // Middle fill color—use a neutral “metal” mid; tweak the mix factor to taste.
//     vec3 midBase = mix(lightC, darkC, 0.55);
//     midCol = midBase;

//     // Optional: snap t to pixel rows to stabilize thickness (helps with jitter):
//     // (Only do this if your distance units are pixels.)
//     // float t_snap = (floor(t * b + 0.5)) / max(b, 1.0);
//     // t = t_snap;

//     // Hard steps (crisp bands). If you want slightly softer edges, replace the
//     // step transitions with a tiny smoothstep around the boundaries.
//     float tOuterEnd = outerN;
//     float tInnerBeg = 1.0 - innerN;

//     // Piecewise selection
//     if (t < tOuterEnd) {
//         return outerCol;
//     } else if (t > tInnerBeg) {
//         return innerCol;
//     } else {
//         return midCol;
//     }
// }
vec3 bevel_color(float b)
{
    // ... (keep your existing band setup) ...

    float outerN = OUTER_BAND_PX / max(b, 0.0001);
    float innerN = INNER_BAND_PX / max(b, 0.0001);
    float totalN = outerN + innerN;
    if (totalN > 0.9) {
        outerN *= 0.9 / totalN;
        innerN *= 0.9 / totalN;
    }

    float dl = texcoord.x;
    float dr = window_size.x - texcoord.x;
    float dt = texcoord.y;
    float db = window_size.y - texcoord.y;

    float m = min(min(dl, dr), min(dt, db));

    // Check if we're in a rounded corner region
    vec2 corner_center;
    bool in_corner = false;

    if (dl < corner_radius && dt < corner_radius) {
        // Top-left corner
        corner_center = vec2(corner_radius, corner_radius);
        in_corner = true;
    } else if (dr < corner_radius && dt < corner_radius) {
        // Top-right corner
        corner_center = vec2(window_size.x - corner_radius, corner_radius);
        in_corner = true;
    } else if (dr < corner_radius && db < corner_radius) {
        // Bottom-right corner
        corner_center = vec2(window_size.x - corner_radius, window_size.y - corner_radius);
        in_corner = true;
    } else if (dl < corner_radius && db < corner_radius) {
        // Bottom-left corner
        corner_center = vec2(corner_radius, window_size.y - corner_radius);
        in_corner = true;
    }

    float t;
    vec3 outerCol, midCol, innerCol;
    if (in_corner) {
        // In corner: use radial distance from corner center
        float dist_from_center = distance(texcoord, corner_center);
        float outer_radius = corner_radius;
        float inner_radius = corner_radius - b;

        // Normalized position within the border ring
        t = clamp01((outer_radius - dist_from_center) / b);

        // Determine which corner to decide light/dark orientation
        bool is_top = texcoord.y < corner_center.y;
        bool is_left = texcoord.x < corner_center.x;

        if ((is_top && is_left) || (!is_top && is_left)) {
            // Top-left or bottom-right: light outside, dark inside
            outerCol = lightC;
            innerCol = darkC;
        } else {
            // Top-right or bottom-left: dark outside, light inside
            outerCol = darkC;
            innerCol = lightC;
        }
    }
    else {
        // Regular edge logic (your existing code)
        if (m == dl) {
            t = clamp01(dl / b);
            outerCol = lightC;
            innerCol = darkC;
        } else if (m == dt) {
            t = clamp01(dt / b);
            outerCol = lightC;
            innerCol = darkC;
        } else if (m == dr) {
            t = clamp01(dr / b);
            outerCol = darkC;
            innerCol = lightC;
        } else {
            t = clamp01(db / b);
            outerCol = darkC;
            innerCol = lightC;
        }
    }

    vec3 midBase = mix(lightC, darkC, 0.55);
    midCol = midBase;

    float tOuterEnd = outerN;
    float tInnerBeg = 1.0 - innerN;

    if (t < tOuterEnd) {
        return outerCol;
    } else if (t > tInnerBeg) {
        return innerCol;
    } else {
        return midCol;
    }
}
// ---- Picom entry point (no main(), like the repo) ----
vec4 window_shader() {
  // Base sample, then apply repo’s default post-processing so we “paint over” afterwards
  vec4 c = texelFetch(tex, ivec2(texcoord), 0);
  c = default_post_processing(c);

  // Only consider fully opaque base pixels (matches the original logic),
  // AND only paint the border area (including rounded corners via corner()).
  bool rounded =
        corner(true,  true,  corner_radius,               corner_radius)
        || corner(false, true,  window_size.x-corner_radius, corner_radius)
        || corner(false, false, window_size.x-corner_radius, window_size.y-corner_radius)
        || corner(true,  false, corner_radius,               window_size.y-corner_radius);

  bool is_border = in_border(texcoord, window_size, border_width) || rounded;

  if (c.a == 1.0 && is_border) {
    // Relief cut has priority

    if (in_relief(ivec2(texcoord),window_size,relief_offset)) {
      c.rgb = darkC;
      return c;
    }

    if (in_relief(ivec2(texcoord),window_size,relief_offset+1)) {
      c.rgb = lightC*0.8;
      return c;
    }




    // Otherwise, beveled gradient on the four sides
    c.rgb = bevel_color(border_width);
    return c;
  }

  // Non-border pixels: pass through
  return c;
}
