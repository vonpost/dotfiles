let
  contextSize = 196608;
in
{
  inherit contextSize;
  host = "0.0.0.0";
  port = 8888;
  model = null;
  modelsDir = "/var/lib/llama-cpp/models/";
  extraFlags = [
    "--jinja"
    "--sleep-idle-seconds" "300"
    "--models-max" "1"
    # Keep the entire slot budget available to a single request.
    "--parallel" "1"
    # Qwen3.6-35B-A3B only uses full attention every 4th layer, so an
    # aggressive 192 Ki token window is realistic on 16 GiB VRAM if the KV
    # cache is quantized and the working buffers stay small.
    "--ctx-size" (toString contextSize)
    "--cache-type-k" "q4_0"
    "--cache-type-v" "q4_0"
    "--flash-attn" "on"
    "--n-gpu-layers" "auto"
    "--batch-size" "1024"
    "--ubatch-size" "512"
  ];
}
