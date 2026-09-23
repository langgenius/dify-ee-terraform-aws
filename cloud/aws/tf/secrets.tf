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

# Main application secret key (chart: global.appSecretKey and the {{secret_key}}
# placeholder consumed by sandbox.apiKey, enterprise.appSecretKey / innerApi etc.).
# Persisted in TF state so re-runs of scripts/4_generate_dify_helm.sh keep the
# same key — rotating it invalidates credentials encrypted at rest in the
# database (model provider keys, etc.). Before this existed, script 4 fell back
# to a fresh `openssl rand -base64 42` on every run and silently rotated the key.
resource "random_bytes" "app_secret_key" {
  length = 42
}
