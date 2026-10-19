/// Contract for the future cloud storage layer.
///
/// The current server implementation uses SQLite for local/single-station
/// deployment. Cloud deployments should implement this contract with a
/// MySQL/PostgreSQL adapter without changing the Flutter feature layer.
enum SaqiaSqlDialect { sqlite, mysql, postgresql }

abstract interface class SaqiaStorageContract {
  SaqiaSqlDialect get dialect;
  Future<void> migrate();
  Future<void> transaction(Future<void> Function() action);
}
