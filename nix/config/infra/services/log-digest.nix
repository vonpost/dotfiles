{ config, lib, ... }:
let
  svc = import ./lib.nix { inherit config lib; };
  llamaCppCfg = import ./llama-cpp-config.nix;
  topology = config.my.infra.topology;
  topo = import ../../../lib/infra-topology.nix { inherit topology; };
  vms = config.my.infra.vms;
  llmVms =
    builtins.filter
      (vmName: builtins.elem "llama-cpp" (vms.${vmName}.services or [ ]))
      (builtins.attrNames vms);
  llmVm =
    if llmVms == [ ] then null else lib.head llmVms;
  llmUrl =
    if llmVm == null
    then "http://127.0.0.1"
    else "http://${topo.getPrimaryIp llmVm}";
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
      port = svc.getPort "llama_server";
      lokiUrl = "http://${topo.getPrimaryIp config.my.infra.observability.lokiVM}:${toString (svc.getPort "loki_http")}";
      allowedIPAddresses = [ "127.0.0.1/32" "::1/128"
        (topo.getPrimaryIp config.my.infra.observability.lokiVM)
      ] ++ lib.optional (llmVm != null) (topo.getPrimaryIp llmVm);
      observeAllowedIPAddresses = [ "127.0.0.1/32" "::1/128"
        (topo.getPrimaryIp config.my.infra.observability.lokiVM)
      ];

      # Runs five minutes after the GPU window opens, so the model is resident by
      # the time the first request lands. See llama-cpp.nix for the window itself.
      reasonOnCalendar = llamaCppCfg.gpuWindowStart;

      # Two sessions share a durable notebook. At most 40 minutes of target
      # compute per night, split three hours apart; unused allowance is not spent.
      gpuBudgetSeconds = 1200;
      synthesisReserveSeconds = 360;

      # Internet background radiation and Loki's own housekeeping. Both are high
      # volume and carry no operational signal, so they are counted but never
      # narrated. Excluding them is what stops every digest opening with a
      # paragraph about firewall drops.
      noiseServices = [ "firewall" "loki" ];
    };
  };
}
