/// Loads the signing key required for server-issued JWTs.
///
/// This server is network-facing and must never silently use a checked-in or
/// otherwise predictable key. Use a randomly generated secret of at least 32
/// characters supplied through the runtime environment.
String requireJwtSecret(Map<String, String> environment) {
  final secret = environment['SAQIA_JWT_SECRET']?.trim();
  if (secret == null || secret.length < 32) {
    throw StateError(
      'SAQIA_JWT_SECRET must be set to a random value of at least 32 characters.',
    );
  }
  return secret;
}
