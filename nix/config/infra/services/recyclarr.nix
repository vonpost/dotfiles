{config, lib, pkgs, ...}:
{
  config = let
    svc = import ./lib.nix { inherit config lib; };
  in lib.mkIf (svc.hasService "recyclarr") {
    services.recyclarr = {
      enable = true;

      configuration = {
        sonarr.sonarrMain = {
          api_key = "";
          base_url = "http://localhost:${toString config.services.sonarr.settings.server.port}";
          delete_old_custom_formats = true;

          quality_definition.type = "series";
          quality_profiles = [
            {
              trash_id = "72dae194fc92bf828f32cde7744e51a1"; # WEB-1080p
              reset_unmatched_scores.enabled = true;
            }
            {
              trash_id = "20e0fc959f1f1704bed501f23bdae76f"; # [Anime] Remux-1080p
              reset_unmatched_scores.enabled = true;
            }
          ];
          custom_format_groups.add = [
            { trash_id = "158188097a58d7687dee647e04af0da3"; } # [Optional] Golden Rule HD
            { trash_id = "74aff4168620ed49dcc67e92b2c2a5b4"; } # [Optional] Language Profiles
            { trash_id = "85fae4a2294965b75710ef2989c850eb"; } # [Streaming Services] HD/UHD boost
            { trash_id = "59c3af66780d08332fdc64e68297098f"; } # [Unwanted] Unwanted Formats
          ];

          # Minimal manual rule: enforce original language only for anime profile
          custom_formats = [
            {
              trash_ids = [
                "ae575f95ab639ba5d15f663bf019e3e8" # Language: Not Original
              ];
              assign_scores_to = [
                { name = "[Anime] Remux-1080p"; score = -10000; }
              ];
            }
          ];
        };

        radarr.radarrMain = {
          api_key = "";
          base_url = "http://localhost:${toString config.services.radarr.settings.server.port}";
          delete_old_custom_formats = true;

          quality_definition.type = "movie";
          quality_profiles = [
            {
              trash_id = "d1d67249d3890e49bc12e275d989a7e9"; # HD Bluray + WEB
              reset_unmatched_scores.enabled = true;
            }
          ];
          custom_format_groups.add = [
            { trash_id = "f8bf8eab4617f12dfdbd16303d8da245"; } # [Optional] Golden Rule HD
            { trash_id = "a3ac6af01d78e4f21fcb75f601ac96df"; } # [Unwanted] Unwanted Formats
          ];
        };
      };
    };

    systemd.services.recyclarr = {
      preStart = lib.mkForce ''
        set -euo pipefail
        tmpfile="$(mktemp)"

        # Start from base JSON, then set fields from environment.
        printf '%s' ${lib.escapeShellArg (builtins.toJSON config.services.recyclarr.configuration)} \
          | ${pkgs.jq}/bin/jq --rawfile radarr_k "$CREDENTIALS_DIRECTORY/recyclarr_radarr_api_key" \
            --rawfile sonarr_k "$CREDENTIALS_DIRECTORY/recyclarr_sonarr_api_key" \
          '
          .radarr.radarrMain.api_key = ($radarr_k | rtrimstr("\n"))
          | .sonarr.sonarrMain.api_key = ($sonarr_k | rtrimstr("\n"))
          ' \
          > "$tmpfile"
        install -m 0600 "$tmpfile" /var/lib/recyclarr/config.yml
        rm -f "$tmpfile"

      '';
    };
  };
}
