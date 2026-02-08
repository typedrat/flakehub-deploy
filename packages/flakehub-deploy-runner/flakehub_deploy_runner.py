#!/usr/bin/env python3
"""
FlakeHub deployment runner with Discord notifications.

Resolves FlakeHub references, applies NixOS configurations, and sends
notifications on deployment status.
"""

import argparse
import logging
import os
import socket
import subprocess
import sys
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

import httpx

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)


class Color(Enum):
    """Discord embed colors (as decimal integers from hex RGB)."""

    BLUE = 0x3498DB
    GREEN = 0x57F287
    YELLOW = 0xFEE75C
    RED = 0xED4245


@dataclass
class DeployConfig:
    """Deployment configuration."""

    flake_ref: str
    configuration: str
    operation: str
    state_dir: Path
    discord_webhook_url: str | None
    rollback_enabled: bool

    @classmethod
    def from_env(cls) -> "DeployConfig":
        """Load configuration from environment variables."""
        state_dir = Path(os.environ.get("STATE_DIR", "/var/lib/flakehub-deploy"))

        discord_url = None
        discord_file = os.environ.get("DISCORD_WEBHOOK_FILE")
        if discord_file:
            try:
                discord_url = Path(discord_file).read_text().strip()
            except (FileNotFoundError, PermissionError):
                logger.warning(f"Could not read Discord webhook file: {discord_file}")

        return cls(
            flake_ref=os.environ["FLAKE_REF"],
            configuration=os.environ.get("CONFIGURATION", socket.gethostname()),
            operation=os.environ.get("OPERATION", "switch"),
            state_dir=state_dir,
            discord_webhook_url=discord_url,
            rollback_enabled=os.environ.get("ROLLBACK_ENABLED", "true").lower()
            == "true",
        )


def send_discord_notification(
    webhook_url: str | None,
    title: str,
    message: str,
    color: Color = Color.BLUE,
) -> None:
    """Send a notification to Discord."""
    if not webhook_url:
        logger.debug("No Discord webhook URL configured, skipping notification")
        return

    payload = {
        "embeds": [
            {
                "title": title,
                "description": message,
                "color": color.value,
            }
        ]
    }

    try:
        response = httpx.post(
            webhook_url,
            json=payload,
            timeout=10.0,
        )
        response.raise_for_status()
        logger.debug("Discord notification sent successfully")
    except httpx.HTTPError as e:
        logger.warning(f"Failed to send Discord notification: {e}")


def run_command(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run a command and return the result."""
    logger.debug(f"Running: {' '.join(cmd)}")
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def resolve_flake_ref(flake_ref: str) -> str:
    """Resolve a FlakeHub reference to a specific version."""
    result = run_command(["fh", "resolve", flake_ref])
    return result.stdout.strip()


def apply_configuration(
    flake_ref: str, configuration: str, operation: str
) -> subprocess.CompletedProcess:
    """Apply a NixOS configuration using fh apply."""
    return run_command(
        [
            "fh",
            "apply",
            "nixos",
            flake_ref,
            "--configuration",
            configuration,
            "--operation",
            operation,
        ],
        check=False,
    )


def rollback() -> bool:
    """Attempt to rollback to the previous generation."""
    try:
        run_command(["nixos-rebuild", "switch", "--rollback"])
        return True
    except subprocess.CalledProcessError:
        return False


def deploy(config: DeployConfig) -> int:
    """Run the deployment process."""
    hostname = socket.gethostname()
    state_file = config.state_dir / "current-version"

    # Ensure state directory exists
    config.state_dir.mkdir(parents=True, exist_ok=True)

    logger.info(
        f"Resolving FlakeHub reference: "
        f"{config.flake_ref}#nixosConfigurations.{config.configuration}"
    )

    # Resolve the current version from FlakeHub
    try:
        resolved = resolve_flake_ref(config.flake_ref)
    except subprocess.CalledProcessError as e:
        error_msg = e.stderr or str(e)
        logger.error(f"Failed to resolve FlakeHub reference: {error_msg}")
        send_discord_notification(
            config.discord_webhook_url,
            "Deployment Failed",
            f"Failed to resolve FlakeHub reference on {hostname}: {error_msg}",
            Color.RED,
        )
        return 1

    logger.info(f"Resolved to: {resolved}")

    # Check if we've already deployed this version
    if state_file.exists():
        current = state_file.read_text().strip()

        if current == resolved:
            logger.info(f"Already at version {resolved}, nothing to do")
            return 0

        if current == f"FAILED:{resolved}":
            logger.info(f"Version {resolved} previously failed, skipping")
            return 0

    logger.info(f"Deploying {resolved} with operation: {config.operation}")
    send_discord_notification(
        config.discord_webhook_url,
        "Deployment Starting",
        f"Deploying {resolved} to {hostname} via {config.operation}",
        Color.YELLOW,
    )

    # Apply the new configuration
    result = apply_configuration(
        config.flake_ref, config.configuration, config.operation
    )

    if result.returncode == 0:
        state_file.write_text(resolved)
        send_discord_notification(
            config.discord_webhook_url,
            "Deployment Succeeded",
            f"Successfully deployed {resolved} to {hostname}",
            Color.GREEN,
        )
        logger.info("Deployment successful!")
        return 0

    # Deployment failed
    logger.error("Deployment failed!")
    logger.error(result.stderr)
    send_discord_notification(
        config.discord_webhook_url,
        "Deployment Failed",
        f"Failed to deploy {resolved} to {hostname}",
        Color.RED,
    )

    # Attempt rollback if enabled
    if config.rollback_enabled:
        logger.info("Attempting rollback...")
        if rollback():
            send_discord_notification(
                config.discord_webhook_url,
                "Rollback Succeeded",
                f"Rolled back {hostname} after failed deployment",
                Color.YELLOW,
            )
            logger.info("Rollback successful")
        else:
            send_discord_notification(
                config.discord_webhook_url,
                "Rollback Failed",
                f"CRITICAL: Failed to rollback {hostname} - manual intervention required",
                Color.RED,
            )
            logger.error("Rollback failed! Manual intervention required.")

    # Mark this version as failed to prevent retry loops
    state_file.write_text(f"FAILED:{resolved}")
    return 1


def main() -> None:
    """Entry point."""
    parser = argparse.ArgumentParser(description="FlakeHub deployment runner")
    parser.add_argument(
        "--flake-ref",
        help="FlakeHub flake reference (overrides FLAKE_REF env var)",
    )
    parser.add_argument(
        "--configuration",
        help="NixOS configuration name (overrides CONFIGURATION env var)",
    )
    parser.add_argument(
        "--operation",
        choices=["switch", "boot"],
        help="nixos-rebuild operation (overrides OPERATION env var)",
    )
    args = parser.parse_args()

    # Override environment with CLI args if provided
    if args.flake_ref:
        os.environ["FLAKE_REF"] = args.flake_ref
    if args.configuration:
        os.environ["CONFIGURATION"] = args.configuration
    if args.operation:
        os.environ["OPERATION"] = args.operation

    try:
        config = DeployConfig.from_env()
    except KeyError as e:
        logger.error(f"Missing required environment variable: {e}")
        sys.exit(1)

    sys.exit(deploy(config))


if __name__ == "__main__":
    main()
