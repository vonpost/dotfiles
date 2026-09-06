# Infrastructure inventory and policy

`inventory.nix` is the ordered list of VMs. Each record contains identity,
resources, service/role assignments, network membership, an explicit primary
network and any hardware-specific modules. `my.infra.vms` is its evaluated
module representation; override that option when testing alternative setups.
`my.infra.topology.vms` is a read-only network projection of the inventory.

Service assignments enable application modules and select catalog metadata for
state, credentials and logging. A resource-only role has `unit = null`: it can
share directories and identity without creating a daemon unit or receiving
daemon credentials. `transcode-worker` deliberately aliases Jellyfin's state
and UID/GID; its shared paths must remain identical on SOTO and OKAMI.

Host staging bind mounts and guest bind mounts come from one state layout. Each
stateful guest receives one VirtioFS state share, plus its read-only store
share. Do not replace this with per-service shares: high VirtioFS concurrency
previously caused host failures.

## Network semantics

`endpoints.nix` defines transport/port pairs. `topology.nix` combines those with
cross-network permissions and external port mappings. Consumers with explicit
service port settings use those evaluated endpoint values. Applications whose
ports are managed in their own persistent configuration still need their
settings kept consistent with the catalog.

The current model trusts network segments:

- `routedFrom` lists additional permitted VM sources across segments. It does
  not restrict same-segment traffic. Guest firewalls open provided ports
  without per-source restrictions.
- Management retains blanket forwarding to other internal segments.
- Same-segment peers reach provided ports directly, without traversing MAMORU.
- DMZ egress restrictions, WAN forwarding and the separate IPv6 policy remain
  as before. IPv4 `routedFrom` entries do not create IPv6 inter-segment grants.
- `primaryVlan` determines DNS, monitoring and DNAT destination addresses. It
  is independent of `assignedVlans` ordering and must belong to that list.

Changing this to per-host isolation is a deliberate policy migration requiring
packet-level tests. The structural refactor does not tighten those rules.

## Logging

Vector collects declared journal units and native journal matches. The digest
includes both its reasoning and collector units. Dashboards are separate data
files under `dashboards/`.

Vector checkpoints remain in the guests' ephemeral `/var/lib/vector`. Making
them durable needs per-VM storage; a shared global Vector state directory would
mix independent journal cursors. Adding persistence to MAMORU or DARE would
also add their first state share, so that is a separate storage/rollout change.
