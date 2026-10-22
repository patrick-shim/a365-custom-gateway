"""Send one prompt to the A365 Gateway evaluation API. No model is called."""

import json
import os
from datetime import datetime, timezone
from getpass import getpass
from http.client import HTTPConnection, HTTPSConnection
from urllib.parse import urlsplit
from uuid import uuid4


gateway = urlsplit(os.getenv("GATEWAY_BASE_URL", "http://127.0.0.1:5080"))
if gateway.scheme not in {"http", "https"} or (
    gateway.scheme == "http" and gateway.hostname not in {"127.0.0.1", "localhost", "::1"}
):
    raise ValueError("GATEWAY_BASE_URL must use HTTPS; HTTP is local-only.")

agent_id = input("External agent ID: ").strip()
agent_key = getpass("Gateway key: ").strip()
user_id = input("Entra user object ID: ").strip()
prompt = input("Prompt [hello world]: ").strip() or "hello world"

body = json.dumps(
    {
        "externalAgentId": agent_id,
        "interactionId": str(uuid4()),
        "occurredAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "userContext": {"tenantUserObjectId": user_id},
        "prompt": {"contentType": "text/plain", "content": prompt},
    }
)

connection_type = HTTPSConnection if gateway.scheme == "https" else HTTPConnection
connection = connection_type(gateway.hostname, gateway.port, timeout=20)
connection.request(
    "POST",
    f"{gateway.path.rstrip('/')}/api/v1/prompts:evaluate",
    body,
    {
        "Authorization": f"Bearer {agent_key}",
        "Content-Type": "application/json",
        "Idempotency-Key": str(uuid4()),
    },
)
response = connection.getresponse()
result = json.loads(response.read())
connection.close()

print(f"\nHTTP {response.status} {response.reason}")
print(json.dumps(result, indent=2))
