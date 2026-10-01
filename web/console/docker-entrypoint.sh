#!/bin/sh
# Write runtime configuration consumed by the SPA (window.__A365_CONFIG__).
# Values come from the container environment so one image serves any deployment.
set -eu

cat > /usr/share/nginx/html/config.js <<EOF
window.__A365_CONFIG__ = {
  clientId: "${CONSOLE_CLIENT_ID:-}",
  tenantId: "${CONSOLE_TENANT_ID:-}",
  apiScope: "${CONSOLE_API_SCOPE:-}",
  useMock: ${CONSOLE_USE_MOCK:-false}
};
EOF
