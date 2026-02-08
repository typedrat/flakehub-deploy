#!/usr/bin/env python3
"""
GitHub webhook handler for FlakeHub deployments.

Validates GitHub webhook signatures and triggers flakehub-deploy.service
when a matching workflow_job completes successfully.
"""

import hashlib
import hmac
import logging
import os
import subprocess
import sys
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="FlakeHub Webhook Handler",
    description="Receives GitHub webhooks and triggers NixOS deployments",
)


class WorkflowJob(BaseModel):
    name: str
    conclusion: str | None = None
    workflow_name: str | None = None


class WebhookPayload(BaseModel):
    action: str
    workflow_job: WorkflowJob | None = None


def get_secret() -> bytes:
    """Load webhook secret from file or environment."""
    secret_file = os.environ.get("WEBHOOK_SECRET_FILE")
    if secret_file:
        return Path(secret_file).read_text().strip().encode()

    secret = os.environ.get("WEBHOOK_SECRET")
    if secret:
        return secret.encode()

    logger.error("No webhook secret configured")
    sys.exit(1)


def get_hostname() -> str:
    """Get the hostname to match against workflow job names."""
    return os.environ.get("HOSTNAME", os.uname().nodename)


def verify_signature(payload: bytes, signature: str, secret: bytes) -> bool:
    """Verify GitHub's HMAC-SHA256 signature."""
    if not signature.startswith("sha256="):
        return False

    expected = hmac.new(secret, payload, hashlib.sha256).hexdigest()
    actual = signature[7:]  # Remove "sha256=" prefix

    return hmac.compare_digest(expected, actual)


def trigger_deployment() -> bool:
    """Trigger the flakehub-deploy systemd service."""
    try:
        subprocess.run(
            ["systemctl", "start", "flakehub-deploy.service"],
            check=True,
            capture_output=True,
        )
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Failed to trigger deployment: {e.stderr.decode()}")
        return False


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "ok"}


@app.post("/hooks/deploy")
async def webhook(
    request: Request,
    x_hub_signature_256: str | None = Header(None),
    x_github_event: str | None = Header(None),
):
    """Handle GitHub webhook events."""
    body = await request.body()

    # Validate signature
    secret = get_secret()
    if not x_hub_signature_256:
        logger.warning("Missing X-Hub-Signature-256 header")
        raise HTTPException(status_code=401, detail="Missing signature")

    if not verify_signature(body, x_hub_signature_256, secret):
        logger.warning("Invalid webhook signature")
        raise HTTPException(status_code=401, detail="Invalid signature")

    # Only process workflow_job events
    if x_github_event != "workflow_job":
        logger.info(f"Ignoring event type: {x_github_event}")
        return {"status": "ignored", "reason": f"event type {x_github_event}"}

    # Parse payload
    try:
        payload = WebhookPayload.model_validate_json(body)
    except Exception as e:
        logger.error(f"Failed to parse payload: {e}")
        raise HTTPException(status_code=400, detail="Invalid payload")

    # Only process completed jobs
    if payload.action != "completed":
        logger.info(f"Ignoring action: {payload.action}")
        return {"status": "ignored", "reason": f"action {payload.action}"}

    if not payload.workflow_job:
        logger.info("No workflow_job in payload")
        return {"status": "ignored", "reason": "no workflow_job"}

    # Check if job name matches our hostname
    hostname = get_hostname()
    job_name = payload.workflow_job.name

    if hostname not in job_name:
        logger.info(f"Job '{job_name}' does not match hostname '{hostname}'")
        return {"status": "ignored", "reason": "hostname mismatch"}

    # Only deploy on success
    if payload.workflow_job.conclusion != "success":
        logger.info(
            f"Job conclusion is '{payload.workflow_job.conclusion}', not 'success'"
        )
        return {"status": "ignored", "reason": "not successful"}

    # Trigger deployment
    logger.info(f"Valid webhook for {hostname}, triggering deployment")

    if trigger_deployment():
        return {"status": "triggered", "hostname": hostname}
    else:
        raise HTTPException(status_code=500, detail="Failed to trigger deployment")


def main():
    """Run the webhook server."""
    import uvicorn

    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "9876"))

    logger.info(f"Starting webhook handler on {host}:{port}")
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    main()
