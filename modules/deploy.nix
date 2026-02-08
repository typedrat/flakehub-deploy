{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.flakehub-deploy;

  stateDir = "/var/lib/flakehub-deploy";
in {
  options.services.flakehub-deploy = {
    enable = mkEnableOption "FlakeHub GitOps deployment";

    flakeRef = mkOption {
      type = types.str;
      example = "my-org/my-config/0.1";
      description = "FlakeHub flake reference (org/repo/version-pattern).";
    };

    configuration = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = "config.networking.hostName";
      description = "NixOS configuration name to deploy. Defaults to the hostname.";
    };

    operation = mkOption {
      type = types.enum ["switch" "boot"];
      default = "switch";
      description = ''
        The nixos-rebuild operation to perform.
        - switch: Apply changes immediately
        - boot: Apply changes on next reboot (safer for workstations)
      '';
    };

    polling = {
      enable = mkEnableOption "fallback polling for deployments";

      interval = mkOption {
        type = types.str;
        default = "15m";
        description = "Polling interval for checking new versions.";
      };
    };

    notification = {
      discord = {
        webhookUrlFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to file containing Discord webhook URL for notifications.";
        };
      };
    };

    rollback = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Automatically rollback to previous generation on deployment failure.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Ensure fh CLI is available
    environment.systemPackages = [pkgs.fh];

    # Main deployment service (triggered by webhook or polling)
    systemd.services.flakehub-deploy = {
      description = "FlakeHub GitOps Deployment";
      after = ["network-online.target"];
      wants = ["network-online.target"];

      environment = {
        FLAKE_REF = cfg.flakeRef;
        CONFIGURATION = cfg.configuration;
        OPERATION = cfg.operation;
        STATE_DIR = stateDir;
        ROLLBACK_ENABLED =
          if cfg.rollback.enable
          then "true"
          else "false";
        DISCORD_WEBHOOK_FILE =
          lib.mkIf (cfg.notification.discord.webhookUrlFile != null)
          cfg.notification.discord.webhookUrlFile;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.flakehub-deploy-runner}/bin/flakehub-deploy-runner";
        StateDirectory = "flakehub-deploy";

        # Security hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [
          stateDir
          "/nix/var/nix"
        ];

        # Required for nixos-rebuild
        Environment = [
          "PATH=${lib.makeBinPath [pkgs.nix pkgs.systemd pkgs.coreutils pkgs.gnugrep pkgs.gawk]}:/run/wrappers/bin"
        ];
      };
    };

    # Polling timer as fallback
    systemd.timers.flakehub-deploy-poll = mkIf cfg.polling.enable {
      description = "FlakeHub Deployment Polling Timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        # Use OnActiveSec instead of OnBootSec to avoid triggering immediately
        # when activating a new NixOS configuration on a system that's been up
        OnActiveSec = "5m";
        OnUnitActiveSec = cfg.polling.interval;
        RandomizedDelaySec = "2m";
        Persistent = false;
      };
    };

    systemd.services.flakehub-deploy-poll = mkIf cfg.polling.enable {
      description = "FlakeHub Deployment Polling";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl start flakehub-deploy.service";
      };
    };
  };
}
