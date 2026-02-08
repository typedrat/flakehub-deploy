{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.flakehub-deploy;
  tunnelCfg = cfg.tunnel;
  webhookCfg = cfg.webhook;
in {
  options.services.flakehub-deploy.tunnel = {
    enable = mkEnableOption "Cloudflare Tunnel for webhook access";

    environmentFile = mkOption {
      type = types.path;
      description = ''
        Path to an environment file containing TUNNEL_TOKEN=<token>.
        Can be generated from a raw token using a secrets manager template
        (e.g., sops.templates or agenix).
      '';
    };
  };

  config = mkIf (cfg.enable && tunnelCfg.enable) {
    assertions = [
      {
        assertion = webhookCfg.enable;
        message = "Cloudflare tunnel requires webhook to be enabled (services.flakehub-deploy.webhook.enable = true)";
      }
    ];

    # Cloudflare tunnel service using token-based authentication
    # The tunnel configuration (ingress rules) should be managed separately (e.g., via Terraform)
    systemd.services.cloudflared-tunnel-deploy = {
      description = "Cloudflare Tunnel for GitOps Deployment";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel run --token \${TUNNEL_TOKEN}";
        Restart = "always";
        RestartSec = "10s";
        EnvironmentFile = tunnelCfg.environmentFile;

        # Security hardening
        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
