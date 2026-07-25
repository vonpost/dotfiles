{ config, lib, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  llamaCppCfg = import ./llama-cpp-config.nix;
  topology = config.my.infra.topology;
  vmServiceMounts = config.my.infra.vmServiceMounts;
  llmVms =
    builtins.filter
      (vmName: builtins.elem "llama-cpp" (vmServiceMounts.${vmName}.serviceMounts or [ ]))
      (builtins.attrNames vmServiceMounts);
  llmVm =
    if llmVms == [ ] then null else lib.head llmVms;
  llmUrl =
    if llmVm == null || topology.domain == ""
    then "http://127.0.0.1"
    else "http://${lib.toLower llmVm}.${topology.domain}";
in
{
  imports = [
    ../../../lib/log-digest.nix
  ];

  config = lib.mkIf (svc.hasService "logDigest") {
    assertions = [
      {
        assertion = builtins.length llmVms == 1;
        message = "services.logDigest requires exactly one VM with the `llama-cpp` service assigned.";
      }
    ];

    services.logDigest = {
      enable = true;
      url = llmUrl;
      model = "Qwen3.6-35B-A3B-UD-Q4_K_XL";
      port = llamaCppCfg.port;

      # Runs five minutes after the GPU window opens, so the model is resident by
      # the time the first request lands. See llama-cpp.nix for the window itself.
      reasonOnCalendar = llamaCppCfg.gpuWindowStart;

      # Measured on this hardware: prefill ~220 tok/s, decode ~15-30 tok/s. The
      # old design burned ~380s per run, over half of it on planner output that
      # was then discarded. This budget is deliberately below that.
      gpuBudgetSeconds = 240;
      synthesisReserveSeconds = 90;

      # Internet background radiation and Loki's own housekeeping. Both are high
      # volume and carry no operational signal, so they are counted but never
      # narrated. Excluding them is what stops every digest opening with a
      # paragraph about firewall drops.
      noiseServices = [ "firewall" "loki" ];
    };
  };
}
