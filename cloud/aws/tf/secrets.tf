# AES-256 key for Dify Enterprise password-policy encryption
# (chart: enterprise.passwordEncryptionKey; DB: enterprise.sys_settings.PASSWORD_POLICY).
# Generated once and persisted in TF state, so the key is stable across terraform
# applies and across re-runs of scripts/4_generate_dify_helm.sh. Rotating it
# invalidates any password-policy ciphertext already stored in the database.
resource "random_bytes" "password_encryption_key" {
  length = 32
}

# Secret key for the agent-backend service (chart 3.12.0+: agentBackend.serverSecretKey,
# env DIFY_AGENT_SERVER_SECRET_KEY). The service validates the value as UNPADDED
# base64url text — the standard-base64 APP_SECRET_KEY ("+"/"/"/"=") is rejected at
# startup, so it needs a dedicated key. Generated once and persisted in TF state,
# stable across applies and re-runs of scripts/4_generate_dify_helm.sh.
resource "random_bytes" "agent_backend_secret_key" {
  length = 32
}
