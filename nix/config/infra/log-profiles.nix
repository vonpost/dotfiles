{
  firewall = {
    description = "Kernel journal entries emitted by the gateway/firewall VM.";
    journalMatches = {
      _TRANSPORT = [ "kernel" ];
    };
    labels = {
      category = "network";
    };
  };
}
