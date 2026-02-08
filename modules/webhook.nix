{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption mkPackageOption types;
  cfg = config.services.flakehub-deploy;
  webhookCfg = cfg.webhook;
in {
  options.services.flakehub-deploy.webhook = {
    enable = mkEnableOption "webhook listener for GitHub deployments";

    package =
      mkPackageOption pkgs "flakehub-webhook-handler" {
        default = null;
        nullable = true;
      }
      // {
        description = ''
          The flakehub-webhook-handler package to use. If null, you must add
          the package to the module's nixpkgs overlay or provide it via specialArgs.
        '';
      };

    port = mkOption {
      type = types.port;
      default = 9876;
      description = "Port for the webhook listener.";
    };

    secretFile = mkOption {
      type = types.path;
      description = ''
        Path to file containing the GitHub webhook secret for HMAC validation.
        This should be a plain text file containing only the secret.
      '';
    };
  };

  config = mkIf (cfg.enable && webhookCfg.enable) {
    assertions = [
      {
        assertion = webhookCfg.package != null;
        message = ''
          services.flakehub-deploy.webhook.package must be set.
          Either provide the flakehub-webhook-handler package directly or add
          the flakehub-deploy flake's overlay to your nixpkgs.
        '';
      }
    ];

    # Webhook service using FastAPI handler
    systemd.services.flakehub-webhook-handler = {
      description = "GitHub Webhook Handler for FlakeHub Deploy";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      environment = {
        HOST = "127.0.0.1";
        PORT = toString webhookCfg.port;
        WEBHOOK_SECRET_FILE = "%d/webhook-secret";
        HOSTNAME = config.networking.hostName;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${webhookCfg.package}/bin/flakehub-webhook-handler";
        Restart = "always";
        RestartSec = "10s";

        # Load the webhook secret via LoadCredential
        LoadCredential = "webhook-secret:${webhookCfg.secretFile}";

        # Security hardening
        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        SystemCallFilter = ["@system-service" "~@privileged"];
      };

      # Allow the webhook handler to trigger systemd services
      path = [pkgs.systemd];
    };

    # Polkit rule to allow webhook service to start flakehub-deploy
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "flakehub-deploy.service" &&
            action.lookup("verb") == "start") {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
