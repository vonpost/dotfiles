# The host and guests must agree on the tree exported through the single state
# share. Keep the relative staging path separate from the application's path.
{ lib, infra }:
let
  state = infra.state;
  mkMount = relativePath: source: mountPoint: {
    inherit relativePath source mountPoint;
    guestSource = "/state/${lib.removePrefix "./" relativePath}";
  };

  serviceMounts = service:
    [
      (mkMount "${state.paths.lib}/${service.name}"
        "${state.paths.base}/${state.paths.lib}/${service.name}"
        "/var/lib/${service.bindTarget}")
    ]
    ++ lib.optional service.hasCacheDir
      (mkMount "${state.paths.cache}/${service.name}"
        "${state.paths.base}/${state.paths.cache}/${service.name}"
        "/var/cache/${service.bindTarget}");

  sharedMount = kind:
    mkMount state.paths.${kind} state.paths."${kind}Root" "/data/${kind}";
in
{
  forVm = hostname:
    let
      services = builtins.filter (service: service.managedState)
        (map (name: infra.services.${name}) infra.vms.${hostname}.services);
      sharedKinds = builtins.filter
        (kind: builtins.any (service: service."${kind}Group") services)
        [ "downloads" "media" ];
    in
    {
      inherit services;
      stagePath = "${state.stageRoot}/${hostname}";
      mounts = lib.concatMap serviceMounts services ++ map sharedMount sharedKinds;
    };

  inherit serviceMounts sharedMount;
}
