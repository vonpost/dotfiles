{config, ...}:
{
  services.recyclarr = {
    enable = true;

    configuration = {
      sonarr.sonarrMain = {
        base_url = "http://localhost:${toString config.services.sonarr.settings.server.port}";
        delete_old_custom_formats = true;
        replace_existing_custom_formats = true;

        include = [
          # Quality sizes (only once)
          { template = "sonarr-quality-definition-series"; }

          # Normal TV (1080p web)
          { template = "sonarr-v4-quality-profile-web-1080p"; }
          { template = "sonarr-v4-custom-formats-web-1080p"; }

          # Anime profile + CFs
          { template = "sonarr-quality-definition-anime"; }
          { template = "sonarr-v4-quality-profile-anime"; }
          { template = "sonarr-v4-custom-formats-anime"; }
        ];

        # Minimal manual rule: enforce original language only for anime profile
        custom_formats = [
          {
            trash_ids = [
              "d6e9318c875905d6cfb5bee961afcea9" # Language: Not Original
            ];
            assign_scores_to = [
              # MUST match the profile name created by the template.
              # If it differs in your Sonarr after first sync, change this string.
              { name = "Remux-1080p - Anime"; score = -10000; }
            ];
          }
        ];
      };

      radarr.radarrMain = {
        base_url = "http://localhost:${toString config.services.radarr.settings.server.port}";
        delete_old_custom_formats = true;
        replace_existing_custom_formats = true;

        include = [
          # Quality sizes (only once)
          { template = "radarr-quality-definition-movie"; }

          # HD-only profile + CFs (no 2160p/UHD templates)
          { template = "radarr-quality-profile-hd-bluray-web"; }
          { template = "radarr-custom-formats-hd-bluray-web"; }
        ];
      };
    };
  };
}
