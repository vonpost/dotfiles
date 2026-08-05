"""Translate a Jellyfin-generated NVENC/CUDA ffmpeg argv into a software one.

Both okuri endpoints use this: the target wrapper when the GPU is unhealthy
(or an attempt just failed), and the controller when it falls back to running
locally on a GPU-less host. The translation is deliberately best-effort: the
original command has already failed (or is guaranteed to fail), so any
exception here falls back to returning the argv unchanged rather than raising.
"""

# Options that only make sense with a hardware pipeline. All of them take a
# value, so they are dropped together with the following argument. Matched on
# the option base name (stream specifiers like ":v:0" stripped).
_DROP_WITH_VALUE = {
    "-init_hw_device",
    "-filter_hw_device",
    "-hwaccel",
    "-hwaccel_output_format",
    "-hwaccel_device",
    "-hwaccel_flags",
    "-extra_hw_frames",
    # nvenc-only encoder options with no direct libx26x equivalent
    "-gpu",
    "-surfaces",
    "-rc",
    "-rc-lookahead",
    "-cq",
    "-spatial-aq",
    "-spatial_aq",
    "-temporal-aq",
    "-temporal_aq",
    "-b_ref_mode",
    "-multipass",
    "-weighted_pred",
    "-dpb_size",
    "-no-scenecut",
    "-strict_gop",
}

_ENCODER_MAP = {
    "h264_nvenc": "libx264",
    "hevc_nvenc": "libx265",
    "av1_nvenc": "libsvtav1",
}

# nvenc p1 (fastest) .. p7 (slowest) onto x264/x265 preset names.
_NVENC_PRESET_MAP = {
    "p1": "ultrafast",
    "p2": "superfast",
    "p3": "veryfast",
    "p4": "fast",
    "p5": "medium",
    "p6": "slow",
    "p7": "slower",
}

# Same, for libsvtav1 whose presets are numeric (13 fastest .. 0 slowest).
_SVTAV1_PRESET_MAP = {
    "p1": "12", "p2": "11", "p3": "10", "p4": "9",
    "p5": "8", "p6": "7", "p7": "6",
}

# A CPU fallback exists to keep playback alive, not to win quality contests:
# never run slower than this x264/x265 preset.
_X26X_SPEED_ORDER = [
    "ultrafast", "superfast", "veryfast", "faster", "fast",
    "medium", "slow", "slower", "veryslow", "placebo",
]
DEFAULT_PRESET_CEILING = "veryfast"

# nvenc tune values; x264/x265 tunes are a disjoint set (film, animation, ...)
_NVENC_TUNES = {"hq", "ll", "ull", "lossless", "uhq"}

_GPU_MARKERS = ("cuda", "nvenc", "cuvid", "nvdec", "_npp")

# Capability-probe style invocations: quick, chatty, safe to multiplex over a
# persistent ssh connection. Anything else is a potentially long-running
# transcode that must own its TCP connection so that killing the dispatcher
# reliably tears the remote process down.
SPECIAL_FLAGS = frozenset({
    "-version", "-encoders", "-decoders", "-hwaccels", "-filters",
    "-muxers", "-demuxers", "-h", "-buildconf", "-fp_format",
})


def is_probe_invocation(role, args):
    return role == "ffprobe" or any(a in SPECIAL_FLAGS for a in args)

# stderr substrings that identify a GPU-level failure (as opposed to a bad
# input file or a genuine encode error that software would hit too). Kept
# specific on purpose: a real NVENC open failure prints OpenEncodeSessionEx
# before ffmpeg's generic "Error while opening encoder" line, so the generic
# form is deliberately absent (it also fires for bad libx264 params).
GPU_ERROR_SIGNATURES = (
    "openencodesessionex failed",
    "no capable devices found",
    "no nvenc capable devices",
    "cannot load libnvidia-encode",
    "cannot load libcuda",
    "cannot load nvcuda",
    "cuda_error",
    "failed setup for format cuda",
    "hwaccel initialisation returned error",
    "impossible to convert between the formats",
    "device creation failed",
)

# Option names whose values can reference the GPU pipeline. wants_gpu only
# inspects these — never positional args like input paths, so a file called
# "Barracuda (1978).mkv" does not get routed through the GPU branch.
_GPU_VALUE_FLAGS = frozenset({
    "-c", "-codec", "-vcodec",
    "-hwaccel", "-hwaccel_output_format", "-hwaccel_device",
    "-init_hw_device", "-filter_hw_device",
    "-vf", "-filter", "-filter_complex",
})


def wants_gpu(args):
    """True when the argv selects the CUDA/NVENC pipeline via codec, hwaccel,
    hw-device or filter options."""
    for i, arg in enumerate(args[:-1]):
        if _base_flag(arg) in _GPU_VALUE_FLAGS:
            low = args[i + 1].lower()
            if any(m in low for m in _GPU_MARKERS):
                return True
    return False


def stderr_looks_gpu_related(stderr_tail):
    low = stderr_tail.lower()
    return any(sig in low for sig in GPU_ERROR_SIGNATURES)


def _base_flag(arg):
    """'-codec:v:0' -> '-codec'; non-flags return None."""
    if not arg.startswith("-") or len(arg) < 2:
        return None
    return arg.split(":", 1)[0]


def _split_graph(value, seps):
    """Split a filtergraph string on top-level separators, honouring single
    quotes and backslash escapes (Jellyfin escapes commas in file names)."""
    parts, buf, quoted, escaped = [], [], False, False
    for ch in value:
        if escaped:
            buf.append(ch)
            escaped = False
            continue
        if ch == "\\":
            buf.append(ch)
            escaped = True
            continue
        if ch == "'":
            quoted = not quoted
            buf.append(ch)
            continue
        if ch in seps and not quoted:
            parts.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    parts.append("".join(buf))
    return parts


def _split_filter(filt):
    """'[a]scale_cuda=w=1:h=2[b]' -> ('[a]', 'scale_cuda', 'w=1:h=2', '[b]')"""
    body = filt
    in_labels = ""
    while body.startswith("["):
        end = body.index("]") + 1
        in_labels += body[:end]
        body = body[end:]
    out_labels = ""
    while body.endswith("]") and "[" in body:
        start = body.rindex("[")
        # Guard against '[' inside a parameter value (e.g. quoted paths).
        if "'" in body[start:]:
            break
        out_labels = body[start:] + out_labels
        body = body[:start]
    name, sep, params = body.partition("=")
    return in_labels, name.strip(), params if sep else None, out_labels


def _join_filter(in_labels, name, params, out_labels):
    body = name if params is None else f"{name}={params}"
    return f"{in_labels}{body}{out_labels}"


def _rewrite_scale_cuda(params, notes):
    """scale_cuda/scale_npp -> scale (+ trailing format=... when requested)."""
    kept, fmt = [], None
    for p in _split_graph(params or "", ":"):
        key, sep, val = p.partition("=")
        if key == "format" and sep:
            fmt = val
        elif key in ("interp_algo", "passthrough", "param"):
            notes.append(f"dropped scale_cuda param {p}")
        elif p:
            kept.append(p)
    filters = [("scale", ":".join(kept) if kept else None)]
    if fmt:
        filters.append(("format", fmt))
    return filters


def _rewrite_tonemap_cuda(params, notes):
    """tonemap_cuda -> zscale/tonemap software chain (Jellyfin's CPU shape)."""
    opts = {}
    for p in _split_graph(params or "", ":"):
        key, sep, val = p.partition("=")
        if sep:
            opts[key] = val
    algo = opts.get("tonemap", "hable")
    if algo not in ("none", "clip", "linear", "gamma", "reinhard",
                    "hable", "mobius"):
        notes.append(f"tonemap algo {algo} unsupported in software, using hable")
        algo = "hable"
    desat = opts.get("desat", "0")
    npl = opts.get("peak", "100")
    out_fmt = opts.get("format", "yuv420p")
    notes.append("tonemap_cuda replaced by zscale+tonemap software chain")
    return [
        ("zscale", f"transfer=linear:npl={npl}"),
        ("format", "gbrpf32le"),
        ("tonemap", f"tonemap={algo}:desat={desat}"),
        ("zscale", "transfer=bt709:matrix=bt709:primaries=bt709:range=tv"),
        ("format", out_fmt),
    ]


def _rewrite_filter_value(value, notes):
    out_chains = []
    for chain in _split_graph(value, ";"):
        out_filters = []
        for filt in _split_graph(chain, ","):
            if not filt.strip():
                continue
            in_l, name, params, out_l = _split_filter(filt.strip())
            if name in ("hwupload", "hwupload_cuda", "hwdownload"):
                # Preserve graph links by substituting a passthrough filter;
                # unlabeled occurrences are cleaned up below.
                out_filters.append((in_l, "null", None, out_l))
                notes.append(f"{name} -> null")
            elif name == "format" and params and "cuda" in params:
                out_filters.append((in_l, "null", None, out_l))
                notes.append("format=cuda -> null")
            elif name in ("scale_cuda", "scale_npp"):
                repl = _rewrite_scale_cuda(params, notes)
                _splice(out_filters, in_l, repl, out_l)
                notes.append(f"{name} -> scale")
            elif name == "tonemap_cuda":
                repl = _rewrite_tonemap_cuda(params, notes)
                _splice(out_filters, in_l, repl, out_l)
            elif name == "overlay_cuda":
                out_filters.append((in_l, "overlay", params, out_l))
                notes.append("overlay_cuda -> overlay")
            elif name == "yadif_cuda":
                out_filters.append((in_l, "yadif", params, out_l))
                notes.append("yadif_cuda -> yadif")
            elif name == "bwdif_cuda":
                out_filters.append((in_l, "bwdif", params, out_l))
                notes.append("bwdif_cuda -> bwdif")
            else:
                out_filters.append((in_l, name, params, out_l))

        out_filters = _cleanup_chain(out_filters)
        out_chains.append(
            ",".join(_join_filter(*f) for f in out_filters)
        )
    return ";".join(out_chains)


def _splice(out_filters, in_labels, replacements, out_labels):
    """Insert a multi-filter replacement, keeping graph labels on the ends."""
    for i, (name, params) in enumerate(replacements):
        first = i == 0
        last = i == len(replacements) - 1
        out_filters.append((
            in_labels if first else "",
            name,
            params,
            out_labels if last else "",
        ))


def _cleanup_chain(filters):
    """Drop unlabeled null passthroughs and adjacent duplicate formats."""
    cleaned = []
    for f in filters:
        in_l, name, params, out_l = f
        if name == "null" and not in_l and not out_l and cleaned:
            continue
        if (name == "format" and cleaned
                and cleaned[-1][1] == "format"
                and cleaned[-1][2] == params
                and not in_l and not cleaned[-1][3]):
            continue
        cleaned.append(f)
    # A chain must not be empty; keep a single null if everything vanished.
    return cleaned or [("", "null", None, "")]


def _clamp_preset(preset, ceiling):
    order = _X26X_SPEED_ORDER
    if ceiling not in order:
        # A bad ceiling must not poison the whole rewrite (the catch-all
        # would return the CUDA argv unchanged, guaranteeing failure).
        return preset
    if preset in order and order.index(preset) > order.index(ceiling):
        return ceiling
    return preset


def rewrite_to_software(args, preset_ceiling=DEFAULT_PRESET_CEILING):
    """Return (rewritten_args, notes). Never raises: on any internal error the
    original argv is returned with a note describing the failure."""
    try:
        return _rewrite(list(args), preset_ceiling)
    except Exception as exc:  # noqa: BLE001 - fallback must never crash
        return list(args), [f"rewrite failed, argv left unchanged: {exc!r}"]


def _rewrite(args, preset_ceiling):
    notes = []

    # First pass: which software encoder are we heading to? Determines how
    # -preset values translate.
    target_encoder = None
    for i, arg in enumerate(args[:-1]):
        if _base_flag(arg) in ("-c", "-codec", "-vcodec"):
            mapped = _ENCODER_MAP.get(args[i + 1])
            if mapped:
                target_encoder = mapped

    out = []
    i = 0
    while i < len(args):
        arg = args[i]
        base = _base_flag(arg)
        nxt = args[i + 1] if i + 1 < len(args) else None

        if base in _DROP_WITH_VALUE:
            notes.append(f"dropped {arg} {nxt}")
            i += 2
            continue

        if base in ("-c", "-codec", "-vcodec") and nxt is not None:
            if nxt in _ENCODER_MAP:
                notes.append(f"{nxt} -> {_ENCODER_MAP[nxt]}")
                out.extend([arg, _ENCODER_MAP[nxt]])
                i += 2
                continue
            if nxt.endswith("_cuvid"):
                # Dropping the decoder selection lets ffmpeg pick the default
                # software decoder for the stream.
                notes.append(f"dropped hardware decoder {nxt}")
                i += 2
                continue

        if base == "-preset" and nxt in _NVENC_PRESET_MAP:
            if target_encoder == "libsvtav1":
                mapped = _SVTAV1_PRESET_MAP[nxt]
            else:
                mapped = _clamp_preset(_NVENC_PRESET_MAP[nxt], preset_ceiling)
            notes.append(f"preset {nxt} -> {mapped}")
            out.extend([arg, mapped])
            i += 2
            continue

        if base == "-tune" and nxt in _NVENC_TUNES:
            notes.append(f"dropped nvenc tune {nxt}")
            i += 2
            continue

        if base in ("-vf", "-filter", "-filter_complex") and nxt is not None:
            new_value = _rewrite_filter_value(nxt, notes)
            out.extend([arg, new_value])
            i += 2
            continue

        if base == "-threads" and nxt == "1":
            # Jellyfin pins hardware pipelines to one thread; a software
            # transcode needs all the cores it can get.
            notes.append("-threads 1 -> 0")
            out.extend([arg, "0"])
            i += 2
            continue

        out.append(arg)
        i += 1

    return out, notes
