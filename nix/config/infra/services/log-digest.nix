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
      port = 8888;
      contextWindow = llamaCppCfg.contextSize;
      investigationEnable = true;
      investigationMaxRounds = 10;
      investigationMaxQueriesPerRound = 8;
      investigationMaxTotalQueries = 40;
      investigationPlannerMaxPromptChars = 28000;
      investigationPlannerMaxTokens = 1800;
      summaryMaxTokens = 3000;
      logQueries = [
        {
          title = "PRIORITY: warning..emerg";
          expr = "{vm=~\".+\"}";
          priorityMax = 4;
        }
      ]
      ++ (map (service: {
        title = "SERVICE: ${service}";
        expr = "{service=\"${service}\"}";
      }) [
        "nginx"
        "radarr"
        "sonarr"
        "jellyfin"
        "wolf"
      ]);
    };
  };
}
