# Credential and certificate rotation

Rotate only the credential named by the approved change. Inventory its consumers,
create the replacement, verify use, and then revoke the predecessor. Never print a
secret value in terminal capture, logs, documentation, tickets, or chat.

## Credential types

| Credential | Stored by | Rotation method |
|---|---|---|
| Gateway ingress key | external agent; salted verifier in SQL | Issue replacement through API/Admin UI, update client secret store, revoke old key |
| Admin UI application credential | Key Vault | Create new app password, write through approved non-echoing path, deploy reference, revoke old password |
| Purview automation certificate | Key Vault | Add certificate to app, store new PFX securely, deploy version, verify, remove old certificate |
| Managed identity | Azure/Entra | No secret rotation; review identity replacement/federation as an infrastructure change |
| API OBO assertion | Managed identity FIC | No client secret; rotate by exact FIC/identity replacement only |

## Gateway key

1. Confirm the exact registration and current key IDs in the Admin UI.
2. Issue a replacement. Capture the clear value once into the external agent's
   approved secret store.
3. Update the external agent and submit a harmless bound request.
4. Confirm the new key succeeds for only that registration.
5. Revoke the old key by exact key ID.
6. Confirm the old key is rejected and record only safe key IDs/timestamps.

If issuance returns an unknown outcome, do not issue another key until the
credential lifecycle is reconciled by ID. The clear value is not recoverable.

## Admin UI credential

Use the canonical bounded upgrade path rather than updating Container Apps by hand:

1. verify the current application, Key Vault secret reference, image digest, and
   bootstrap ownership;
2. add one new application password with a bounded expiry;
3. write the value directly to the approved Key Vault secret path without echoing;
4. deploy the Admin UI revision through the reviewed upgrade command;
5. verify sign-in, delegated API access, redirect/logout URIs, and health;
6. remove the predecessor password;
7. verify the application retains only the expected credential set.

## Purview automation certificate

1. Create a new non-exported working certificate or approved PFX according to tenant
   policy.
2. Add its public certificate to the exact automation application.
3. Store the PFX and password through the approved Key Vault/non-echoing mechanism.
4. Deploy the new secret version/reference to the worker.
5. Run exact collection and DLP readback with the new certificate.
6. Verify one approved optional policy operation or safe authentication check.
7. remove the predecessor certificate from the application and vault according to
   retention policy;
8. verify no workload references the old thumbprint/version.

Never use the child Agent ID, blueprint, Gateway key, or signed-in administrator
token as the policy-automation identity.

## Emergency rotation

For suspected compromise, first contain the exact credential: revoke a Gateway key,
disable the application password/certificate, or close the affected admission path.
Preserve safe audit/correlation evidence, follow the incident-response runbook, and
then issue a replacement. Do not delete unrelated identities or credentials.

## Completion record

Record credential type, safe object/key/thumbprint identifier, owner, issue and
revocation times, consuming revision/digest, verification result, and correlation
IDs. Never record the credential value.
