{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkMerge mkOption types;
  cfg = config.services.flakehub-deploy;

  stateDir = "/var/lib/flakehub-deploy";

  # Script to send notifications via Discord webhook
  notifyScript = pkgs.writeShellScript "flakehub-deploy-notify" ''
    set -euo pipefail

    WEBHOOK_URL="$1"
    TITLE="$2"
    MESSAGE="$3"
    COLOR="''${4:-3447003}"  # Default blue

    if [[ -z "$WEBHOOK_URL" ]]; then
      echo "No webhook URL configured, skipping notification"
      exit 0
    fi

    ${pkgs.curl}/bin/curl -s -H "Content-Type: application/json" \
      -d "{\"embeds\":[{\"title\":\"$TITLE\",\"description\":\"$MESSAGE\",\"color\":$COLOR}]}" \
      "$WEBHOOK_URL"
  '';

  # Main deployment script
  deployScript = pkgs.writeShellScript "flakehub-deploy" ''
    set -euo pipefail

    FLAKEREF="${cfg.flakeRef}"
    CONFIGURATION="${cfg.configuration}"
    OPERATION="${cfg.operation}"
    STATE_FILE="${stateDir}/current-version"
    WEBHOOK_URL=""
    ${lib.optionalString (cfg.notification.discord.webhookUrlFile != null) ''
      WEBHOOK_URL="$(cat ${cfg.notification.discord.webhookUrlFile} 2>/dev/null || echo "")"
    ''}

    mkdir -p "${stateDir}"

    # Colors for notifications
    COLOR_GREEN=5763719
    COLOR_RED=15548997
    COLOR_YELLOW=16776960

    notify() {
      local title="$1"
      local message="$2"
      local color="''${3:-3447003}"
      ${notifyScript} "$WEBHOOK_URL" "$title" "$message" "$color"
    }

    echo "Resolving FlakeHub reference: $FLAKEREF#nixosConfigurations.$CONFIGURATION"

    # Resolve the current version from FlakeHub
    RESOLVED=$(${pkgs.fh}/bin/fh resolve "$FLAKEREF" 2>&1) || {
      echo "Failed to resolve FlakeHub reference: $RESOLVED"
      notify "Deployment Failed" "Failed to resolve FlakeHub reference on $(hostname): $RESOLVED" "$COLOR_RED"
      exit 1
    }

    echo "Resolved to: $RESOLVED"

    # Check if we've already deployed this version
    if [[ -f "$STATE_FILE" ]]; then
      CURRENT=$(cat "$STATE_FILE")
      if [[ "$CURRENT" == "$RESOLVED" ]]; then
        echo "Already at version $RESOLVED, nothing to do"
        exit 0
      fi

      # Check for failed state
      if [[ "$CURRENT" == "FAILED:$RESOLVED" ]]; then
        echo "Version $RESOLVED previously failed, skipping"
        exit 0
      fi
    fi

    echo "Deploying $RESOLVED with operation: $OPERATION"
    notify "Deployment Starting" "Deploying $RESOLVED to $(hostname) via $OPERATION" "$COLOR_YELLOW"

    # Apply the new configuration
    if ${pkgs.fh}/bin/fh apply nixos "$FLAKEREF" \
        --configuration "$CONFIGURATION" \
        --operation "$OPERATION"; then
      echo "$RESOLVED" > "$STATE_FILE"
      notify "Deployment Succeeded" "Successfully deployed $RESOLVED to $(hostname)" "$COLOR_GREEN"
      echo "Deployment successful!"
    else
      echo "Deployment failed!"
      notify "Deployment Failed" "Failed to deploy $RESOLVED to $(hostname)" "$COLOR_RED"

      ${lib.optionalString cfg.rollback.enable ''
      echo "Attempting rollback..."
      if ${pkgs.nixos-rebuild}/bin/nixos-rebuild switch --rollback; then
        notify "Rollback Succeeded" "Rolled back $(hostname) after failed deployment" "$COLOR_YELLOW"
        echo "Rollback successful"
      else
        notify "Rollback Failed" "CRITICAL: Failed to rollback $(hostname) - manual intervention required" "$COLOR_RED"
        echo "Rollback failed! Manual intervention required."
      fi
    ''}

      # Mark this version as failed to prevent retry loops
      echo "FAILED:$RESOLVED" > "$STATE_FILE"
      exit 1
    fi
  '';
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

      serviceConfig = {
        Type = "oneshot";
        ExecStart = deployScript;
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
        OnBootSec = "5m";
        OnUnitActiveSec = cfg.polling.interval;
        RandomizedDelaySec = "2m";
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
