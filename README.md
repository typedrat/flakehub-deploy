# flakehub-deploy

A NixOS module for GitOps-style deployments using [FlakeHub](https://flakehub.com).

## Overview

This module enables automated deployments where:

1. CI builds your NixOS configurations and publishes to FlakeHub
2. Target systems receive webhooks when builds complete
3. Systems pull and apply the pre-built configurations via `fh apply nixos`

## Features

- **Webhook-triggered deployments**: Validates GitHub webhook signatures (HMAC-SHA256) and triggers deployments on successful builds
- **Polling fallback**: Periodically checks for new versions if webhooks fail
- **Discord notifications**: Sends deployment status updates to Discord
- **Automatic rollback**: Reverts to previous generation on deployment failure
- **State tracking**: Prevents duplicate deployments and retry loops on failed versions
- **Cloudflare Tunnel support**: Secure webhook ingress without exposing ports

## Installation

Add the flake to your inputs:

```nix
{
  inputs.flakehub-deploy.url = "github:your-org/flakehub-deploy";
  # Or from FlakeHub once published:
  # inputs.flakehub-deploy.url = "https://flakehub.com/f/your-org/flakehub-deploy/*";
}
```

Import the module in your NixOS configuration:

```nix
{ inputs, ... }: {
  imports = [inputs.flakehub-deploy.nixosModules.default];
}
```

## Configuration

### Basic setup with polling only

```nix
{
  services.flakehub-deploy = {
    enable = true;
    flakeRef = "your-org/your-config/0.1";

    polling = {
      enable = true;
      interval = "15m";
    };
  };
}
```

### With webhook listener

```nix
{
  services.flakehub-deploy = {
    enable = true;
    flakeRef = "your-org/your-config/0.1";

    webhook = {
      enable = true;
      port = 9876;
      secretFile = "/run/secrets/webhook-secret"; # GitHub webhook secret
    };

    polling.enable = true; # Fallback
  };
}
```

### With Cloudflare Tunnel

```nix
{
  services.flakehub-deploy = {
    enable = true;
    flakeRef = "your-org/your-config/0.1";

    webhook.enable = true;

    tunnel = {
      enable = true;
      # Environment file containing TUNNEL_TOKEN=<token>
      environmentFile = "/run/secrets/tunnel-env";
    };

    polling.enable = true;
  };
}
```

### With Discord notifications

```nix
{
  services.flakehub-deploy = {
    enable = true;
    flakeRef = "your-org/your-config/0.1";

    notification.discord.webhookUrlFile = "/run/secrets/discord-webhook";

    polling.enable = true;
  };
}
```

## Options

### `services.flakehub-deploy`

| Option            | Type   | Default    | Description                                     |
| ----------------- | ------ | ---------- | ----------------------------------------------- |
| `enable`          | bool   | `false`    | Enable FlakeHub GitOps deployment               |
| `flakeRef`        | string | —          | FlakeHub flake reference (e.g., `org/repo/0.1`) |
| `configuration`   | string | hostname   | NixOS configuration name to deploy              |
| `operation`       | enum   | `"switch"` | `"switch"` or `"boot"`                          |
| `rollback.enable` | bool   | `true`     | Auto-rollback on failure                        |

### `services.flakehub-deploy.polling`

| Option     | Type   | Default | Description             |
| ---------- | ------ | ------- | ----------------------- |
| `enable`   | bool   | `false` | Enable polling fallback |
| `interval` | string | `"15m"` | Polling interval        |

### `services.flakehub-deploy.webhook`

| Option       | Type | Default | Description                           |
| ------------ | ---- | ------- | ------------------------------------- |
| `enable`     | bool | `false` | Enable webhook listener               |
| `port`       | int  | auto    | Port for webhook server               |
| `secretFile` | path | —       | File containing GitHub webhook secret |

### `services.flakehub-deploy.tunnel`

| Option            | Type | Default | Description                            |
| ----------------- | ---- | ------- | -------------------------------------- |
| `enable`          | bool | `false` | Enable Cloudflare Tunnel               |
| `environmentFile` | path | —       | File containing `TUNNEL_TOKEN=<token>` |

### `services.flakehub-deploy.notification.discord`

| Option           | Type | Default | Description                         |
| ---------------- | ---- | ------- | ----------------------------------- |
| `webhookUrlFile` | path | `null`  | File containing Discord webhook URL |

## GitHub Actions Setup

Add a publish job to your workflow:

```yaml
publish:
  needs: build
  if: github.ref == 'refs/heads/main' && needs.build.result == 'success'
  runs-on: ubuntu-latest
  permissions:
    id-token: write
    contents: read
  steps:
    - uses: actions/checkout@v4
    - uses: DeterminateSystems/determinate-nix-action@v3
    - uses: DeterminateSystems/flakehub-push@main
      with:
        visibility: private
        rolling: true
        rolling-minor: "0.1"
        include-output-paths: true
```

Configure a repository webhook:

- **URL**: `https://your-webhook-endpoint/hooks/deploy`
- **Content type**: `application/json`
- **Secret**: Same as `webhook.secretFile`
- **Events**: Select "Workflow jobs"

## Architecture

```
GitHub Actions                     Target System
┌─────────────────┐               ┌──────────────────────────────┐
│ Build & Test    │               │                              │
│       ↓         │               │  ┌─────────────────────┐     │
│ flakehub-push   │───webhook────▶│  │ webhook-handler     │     │
│ (publish)       │               │  │ (validates sig)     │     │
└─────────────────┘               │  └──────────┬──────────┘     │
                                  │             │ systemctl      │
                                  │             ↓                │
                                  │  ┌─────────────────────┐     │
                                  │  │ deploy-runner       │     │
                                  │  │ (fh apply nixos)    │     │
                                  │  └─────────────────────┘     │
                                  │                              │
                                  │  ┌─────────────────────┐     │
                                  │  │ poll timer          │──┐  │
                                  │  │ (fallback)          │  │  │
                                  │  └─────────────────────┘  │  │
                                  │             ↑             │  │
                                  │             └─────────────┘  │
                                  └──────────────────────────────┘
```

## Security

- **Webhook validation**: All incoming webhooks are validated using HMAC-SHA256 signatures
- **Privilege separation**: The webhook handler runs as an unprivileged DynamicUser and triggers the deployment service via polkit
- **No arbitrary code execution**: The flake reference is fixed in the NixOS configuration; webhooks can only trigger deployments, not control what gets deployed

## License

MIT
