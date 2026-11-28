import 'dart:async';

import 'package:redis/redis.dart';

/// The Redis operations [RedisFeatureStore] uses.
abstract interface class RedisCommands {
  Future<String?> get(String key);

  Future<void> set(String key, String value);

  /// `WATCH key`: a following [setAll] fails if [key] changes first.
  Future<void> watch(String key);

  Future<void> unwatch();

  /// Sets [values] in one transaction (`MULTI`, `SET`..., `EXEC`). Returns
  /// false if a watched key changed, in which case nothing was set.
  Future<bool> setAll(Map<String, String> values);

  Future<void> close();
}

/// [RedisCommands] over a connection from the `redis` package.
///
/// The connection must be used by one operation at a time;
/// [RedisFeatureStore] serialises its operations.
class PackageRedisCommands implements RedisCommands {
  final Command _command;
  final RedisConnection? _connection;

  PackageRedisCommands(this._command, [this._connection]);

  /// Connects to Redis at [host]:[port] (over TLS if [secure]), then
  /// authenticates with [password] (and [username], for Redis ACLs) and
  /// selects [database] if given.
  static Future<PackageRedisCommands> connect({
    String host = 'localhost',
    int port = 6379,
    bool secure = false,
    String? username,
    String? password,
    int? database,
  }) async {
    final connection = RedisConnection();
    final command = secure
        ? await connection.connectSecure(host, port)
        : await connection.connect(host, port);
    try {
      if (password != null) {
        await command.send_object(['AUTH', ?username, password]);
      }
      if (database != null) {
        await command.send_object(['SELECT', '$database']);
      }
    } catch (e) {
      await connection.close();
      rethrow;
    }
    return PackageRedisCommands(command, connection);
  }

  @override
  Future<String?> get(String key) async {
    final value = await _command.get(key);
    return value == null ? null : '$value';
  }

  @override
  Future<void> set(String key, String value) => _command.set(key, value);

  @override
  Future<void> watch(String key) => _command.send_object(['WATCH', key]);

  @override
  Future<void> unwatch() => _command.send_object(['UNWATCH']);

  @override
  Future<bool> setAll(Map<String, String> values) async {
    final transaction = await _command.multi();
    for (final e in values.entries) {
      // these complete with EXEC; a failed EXEC never completes them
      transaction.set(e.key, e.value).ignore();
    }
    try {
      await transaction.exec();
      return true;
    } on TransactionError {
      return false;
    }
  }

  @override
  Future<void> close() async => _connection?.close();
}
