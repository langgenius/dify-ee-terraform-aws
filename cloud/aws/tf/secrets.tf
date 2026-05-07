# AES-256 key for Dify Enterprise password-policy encryption
# (chart: enterprise.passwordEncryptionKey; DB: enterprise.sys_settings.PASSWORD_POLICY).
# Generated once and persisted in TF state, so the key is stable across terraform
# applies and across re-runs of scripts/4_generate_dify_helm.sh. Rotating it
# invalidates any password-policy ciphertext already stored in the database.
resource "random_bytes" "password_encryption_key" {
  length = 32
}
