import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = fs.readFileSync(path.join(root, "nginx.conf"), "utf8");

function extractBlock(marker) {
  const start = config.indexOf(marker);
  assert.notEqual(start, -1, `Missing nginx block: ${marker}`);
  const openingBrace = config.indexOf("{", start + marker.length);
  assert.notEqual(openingBrace, -1, `Missing opening brace for nginx block: ${marker}`);

  let depth = 0;
  for (let index = openingBrace; index < config.length; index += 1) {
    if (config[index] === "{") depth += 1;
    if (config[index] === "}") depth -= 1;
    if (depth === 0) return config.slice(openingBrace + 1, index);
  }

  assert.fail(`Missing closing brace for nginx block: ${marker}`);
}

assert.match(
  config,
  /resolver\s+127\.0\.0\.11\s+valid=5s\s+ipv6=off\s*;/,
  "Console proxy must use Docker DNS with a bounded cache.",
);
assert.match(config, /resolver_timeout\s+5s\s*;/, "Console proxy DNS lookup must be bounded.");
assert.match(
  config,
  /set\s+\$gateway_api_origin\s+\$\{GATEWAY_API_ORIGIN\}\s*;/,
  "Gateway origin must remain an environment template and an nginx variable.",
);

const proxyPasses = [...config.matchAll(/proxy_pass\s+([^;]+);/g)].map((match) => match[1].trim());
assert.equal(proxyPasses.length, 3, "API, health, and documentation routes must all be proxied.");
assert.ok(
  proxyPasses.every((value) => value === "$gateway_api_origin"),
  "Every Gateway route must use the dynamically resolved origin.",
);
assert.doesNotMatch(
  config,
  /proxy_pass\s+\$\{GATEWAY_API_ORIGIN\}\s*;/,
  "A startup-resolved proxy_pass would retain a replaced API container address.",
);

const apiLocation = extractBlock("location /api/");
assert.match(apiLocation, /proxy_pass \$gateway_api_origin;/, "API route must use the dynamic origin.");
assert.match(apiLocation, /proxy_set_header Host \$\{GATEWAY_API_HOST\};/, "API host forwarding must remain explicit.");
assert.match(apiLocation, /proxy_set_header Authorization \$http_authorization;/, "API authorization forwarding must remain explicit.");

const healthLocation = extractBlock("location /health");
assert.match(healthLocation, /proxy_pass \$gateway_api_origin;/, "Health route must use the dynamic origin.");
assert.match(healthLocation, /proxy_set_header Host \$\{GATEWAY_API_HOST\};/, "Health host forwarding must remain explicit.");

const docsLocation = extractBlock("location ~ ^/(docs$|scalar(/|$)|openapi/)");
assert.match(docsLocation, /proxy_pass \$gateway_api_origin;/, "API-reference routes must use the dynamic origin.");
assert.match(docsLocation, /proxy_set_header Host \$http_host;/, "API-reference host forwarding must remain explicit.");
assert.match(docsLocation, /proxy_set_header Authorization \$http_authorization;/, "API-reference authorization forwarding must remain explicit.");

console.log("Console proxy config passed: Docker DNS re-resolution and existing route headers are preserved.");
