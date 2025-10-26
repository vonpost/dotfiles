#version 330
in vec2 texcoord;
uniform sampler2D tex;
uniform vec2      effective_size;   // window size in pixels
vec4 default_post_processing(vec4 c);

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453123); }
float noise(vec2 p){
  vec2 i = floor(p), f = fract(p);
  float a = hash(i);
  float b = hash(i + vec2(1,0));
  float c = hash(i + vec2(0,1));
  float d = hash(i + vec2(1,1));
  vec2 u = f*f*(3.0-2.0*f);
  return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
}
float fbm(vec2 p){
  float z = 0.0, amp = 0.6;
  for(int i=0;i<4;i++){ z += amp*noise(p); p *= 2.03; amp *= 0.55; }
  return z;
}

vec4 window_shader(){
  // Sample source
  vec2 texsize = textureSize(tex, 0);
  vec2 uv  = texcoord / texsize;
  vec4 c   = texture(tex, uv);
  vec3 col = c.rgb;

  // --- Edge awareness: reduce grain where there are sharp luminance edges (text) ---
  float l  = dot(col, vec3(0.299,0.587,0.114));
  float dx = dFdx(l), dy = dFdy(l);
  float edge = clamp(abs(dx)+abs(dy), 0.0, 1.0);    // 0 = flat, 1 = edge
  float edgeMask = 1.0 - smoothstep(0.03, 0.12, edge); // less grain on edges

  // --- Multi-scale paper noise (no vignette) ---
  // scale to a consistent world-ish density per window size
  vec2 p = uv * 700.0;
  float g = fbm(p) * 0.5 + fbm(p*0.35)*0.5;         // soft pulp grain
  g = (g - 0.5) * 0.05;                             // amplitude ~5%

  // faint fibers (subtle; safe for text)
  float ang = 1.0;
  vec2 rot = mat2(cos(ang), -sin(ang), sin(ang), cos(ang)) * (uv*700.0*0.6);
  float fibers = smoothstep(0.6, 0.95, noise(vec2(rot.x*4.0, rot.y*0.22))) * 0.065;

  // base tint and grain application with edge mask
  vec3 paperTint = vec3(0.985, 0.983, 0.978);
  col *= paperTint;
  col += (g * edgeMask) + fibers;

  return default_post_processing(vec4(col, c.a));
}
