import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:logging/logging.dart';

import 'redis_commands.dart';

final _log = Logger('featurehub_redis_store');

/// The source [RedisFeatureStore] gives the features it loads (the same as
/// the TypeScript SDK's store).
const redisStoreSource = 'redis-store';

/// Keeps the features in Redis, shared by every process using the same
/// FeatureHub environment.
///
/// In a deployment with several instances (containers, serverless functions,
/// horizontally scaled services), each instance normally keeps its own copy
/// of the features. With this store they share one copy in Redis: updates
/// from FeatureHub reach every instance soon after any one of them receives
/// them, an instance starts with the stored features, and while Redis is
/// available instances keep receiving updates even if their own connection
/// to FeatureHub fails.
///
/// The keys and data are the same as every other FeatureHub SDK's Redis
/// store, so services in different languages can share them:
/// `<prefix>_<environment id>` holds the features as a JSON array and
/// `<prefix>_<environment id>_sha` a SHA-256 of their ids and versions.
/// Writes use optimistic locking (`WATCH`/`MULTI`/`EXEC`), merging by
/// version when another process wrote first, so a newer feature is never
/// replaced by an older one.
///
/// Only client-evaluated API keys are supported: features evaluated by
/// FeatureHub for one context must not be shared with others. Redis Cluster
/// is not supported.
class RedisFeatureStore implements FeatureStore {
  final RedisCommands _redis;

  /// The prefix of the Redis keys.
  final String prefix;

  /// How long to wait before retrying a write that another process
  /// interrupted.
  final Duration backoff;

  /// How many times to try a write before giving up.
  final int retryUpdateCount;

  /// How often to check Redis for features written by other processes.
  final Duration refreshInterval;

  FeatureStoreTarget? _target;
  StreamSubscription<RawFeatureUpdate>? _subscription;
  Timer? _timer;
  String? _lastSha;
  bool _active = false;

  /// Redis operations run one at a time.
  Future<void> _queue = Future.value();

  /// Uses [redis] for its Redis operations (see [RedisFeatureStore.connect]).
  RedisFeatureStore(
    this._redis, {
    this.prefix = 'featurehub',
    this.backoff = const Duration(milliseconds: 500),
    this.retryUpdateCount = 10,
    this.refreshInterval = const Duration(minutes: 5),
  });

  /// Connects to Redis at [host]:[port] (over TLS if [secure]), with
  /// [username]/[password] and [database] if given.
  static Future<RedisFeatureStore> connect({
    String host = 'localhost',
    int port = 6379,
    bool secure = false,
    String? username,
    String? password,
    int? database,
    String prefix = 'featurehub',
    Duration backoff = const Duration(milliseconds: 500),
    int retryUpdateCount = 10,
    Duration refreshInterval = const Duration(minutes: 5),
  }) async => RedisFeatureStore(
    await PackageRedisCommands.connect(
      host: host,
      port: port,
      secure: secure,
      username: username,
      password: password,
      database: database,
    ),
    prefix: prefix,
    backoff: backoff,
    retryUpdateCount: retryUpdateCount,
    refreshInterval: refreshInterval,
  );

  /// Connects to the Redis described by [url]:
  /// `redis://[[username]:password@]host[:port][/database]`, or `rediss://`
  /// for TLS.
  static Future<RedisFeatureStore> fromUrl(
    String url, {
    String prefix = 'featurehub',
    Duration backoff = const Duration(milliseconds: 500),
    int retryUpdateCount = 10,
    Duration refreshInterval = const Duration(minutes: 5),
  }) {
    final uri = Uri.parse(url);
    if (uri.scheme != 'redis' && uri.scheme != 'rediss') {
      throw ArgumentError.value(url, 'url', 'must be a redis:// URL');
    }
    String? username;
    String? password;
    if (uri.userInfo.isNotEmpty) {
      final colon = uri.userInfo.indexOf(':');
      if (colon < 0) {
        password = Uri.decodeComponent(uri.userInfo);
      } else {
        final user = uri.userInfo.substring(0, colon);
        username = user.isEmpty ? null : Uri.decodeComponent(user);
        password = Uri.decodeComponent(uri.userInfo.substring(colon + 1));
      }
    }
    final path = uri.path.replaceAll('/', '');
    return connect(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 6379,
      secure: uri.scheme == 'rediss',
      username: username,
      password: password,
      database: path.isEmpty ? null : int.parse(path),
      prefix: prefix,
      backoff: backoff,
      retryUpdateCount: retryUpdateCount,
      refreshInterval: refreshInterval,
    );
  }

  @override
  bool get connected => _active;

  String get _featuresKey => '${prefix}_${_target!.environmentId}';

  String get _shaKey => '${prefix}_${_target!.environmentId}_sha';

  /// Runs [operation] after every earlier one.
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<void> attach(FeatureStoreTarget target) async {
    if (!target.clientEvaluated) {
      _log.severe(
        'RedisFeatureStore: refusing to attach to a server-evaluated API key. '
        'Sharing features in Redis across server-evaluated contexts would '
        'give incorrect values for different evaluation contexts.',
      );
      return;
    }

    _target = target;
    _subscription = target.repository.rawFeatureUpdates.listen(_update);

    await _serial(() async {
      _lastSha = await _redis.get(_shaKey);
      if (_lastSha != null) await _loadFromRedis();
    });

    _timer = Timer.periodic(refreshInterval, (_) {
      _serial(_refreshFromRedis).catchError((Object e, StackTrace s) {
        _log.warning('RedisFeatureStore: refresh failed', e, s);
      });
    });
    _active = true;
  }

  @override
  Future<void> close() async {
    _active = false;
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
    // let pending writes finish, then release the connection
    await _queue;
    await _redis.close();
  }

  /// Checks for features written by another process.
  Future<void> refresh() => _serial(_refreshFromRedis);

  void _update(RawFeatureUpdate update) {
    if (update.source == redisStoreSource) return;
    final Future<void> Function() handler = switch (update) {
      FeaturesReceived(:final features) => () => _processUpdates(features),
      FeatureReceived(:final feature) => () => _processUpdate(feature),
      FeatureDeleted(:final feature) => () => _deleteFeature(feature),
    };
    _serial(handler).catchError((Object e, StackTrace s) {
      _log.warning('RedisFeatureStore: unable to store $update', e, s);
    });
  }

  // ---- reading

  Future<List<FeatureState>?> _readFeatures() async {
    final raw = await _redis.get(_featuresKey);
    if (raw == null) return null;
    try {
      return FeatureState.listFromJson(jsonDecode(raw));
    } catch (e) {
      _log.fine('RedisFeatureStore: ignoring unreadable features: $e');
      return null;
    }
  }

  Future<void> _loadFromRedis() async {
    final features = await _readFeatures();
    if (features == null) return;
    _target!.repository.notify(
      SSEResultState.features,
      features,
      source: redisStoreSource,
    );
  }

  Future<void> _refreshFromRedis() async {
    if (_target == null) return;
    final sha = await _redis.get(_shaKey);
    if (sha == null || sha == _lastSha) return;
    _lastSha = sha;
    await _loadFromRedis();
  }

  // ---- versions

  static int _version(FeatureState f) => f.version;

  /// The SHA-256 of the features' `id:version`s sorted by id, as every
  /// FeatureHub SDK computes it.
  static String computeSha(List<FeatureState> features) {
    final sorted = [...features]..sort((a, b) => a.id.compareTo(b.id));
    final input = sorted.map((f) => '${f.id}:${_version(f)}').join('|');
    return sha256.convert(utf8.encode(input)).toString();
  }

  static bool _anyIncomingIsNewer(
    List<FeatureState> incoming,
    List<FeatureState> existing,
  ) {
    final versions = {for (final f in existing) f.id: _version(f)};
    return incoming.any((f) => _version(f) > (versions[f.id] ?? -1));
  }

  /// Keeps the higher-versioned copy of each feature.
  static List<FeatureState> _merge(
    List<FeatureState> incoming,
    List<FeatureState> existing,
  ) {
    final merged = {for (final f in existing) f.id: f};
    for (final f in incoming) {
      if (_version(f) > (merged[f.id] == null ? -1 : _version(merged[f.id]!))) {
        merged[f.id] = f;
      }
    }
    return merged.values.toList();
  }

  // ---- writing

  Future<void> _storeFeatures(List<FeatureState> features) async {
    var toWrite = features;
    var sha = computeSha(toWrite);

    for (var attempt = 0; attempt < retryUpdateCount; attempt++) {
      await _redis.watch(_shaKey);
      final current = await _redis.get(_shaKey);

      if (current == sha) {
        await _redis.unwatch();
        _lastSha = sha;
        return;
      }

      if (current != null && current != _lastSha) {
        // another process has written since we last did: check versions
        final stored = await _readFeatures();
        if (stored != null) {
          if (!_anyIncomingIsNewer(toWrite, stored)) {
            await _redis.unwatch();
            return; // ours are all stale
          }
          toWrite = _merge(toWrite, stored);
          sha = computeSha(toWrite);
        }
      }

      final written = await _redis.setAll({
        _shaKey: sha,
        _featuresKey: jsonEncode(toWrite.map((f) => f.toJson()).toList()),
      });
      if (written) {
        _lastSha = sha;
        return;
      }

      // another process wrote in between: try again
      await Future<void>.delayed(backoff);
    }

    _log.severe(
      'RedisFeatureStore: giving up writing after $retryUpdateCount '
      'attempts',
    );
  }

  Future<void> _processUpdates(List<FeatureState> features) async {
    final sha = computeSha(features);
    final stored = await _redis.get(_shaKey);
    if (sha == stored) return;

    if (stored != null) {
      final existing = await _readFeatures();
      if (existing != null && !_anyIncomingIsNewer(features, existing)) return;
    }
    await _storeFeatures(features);
  }

  Future<void> _processUpdate(FeatureState feature) async {
    final stored = await _readFeatures();
    if (stored != null) {
      final existing = stored.where((f) => f.id == feature.id).firstOrNull;
      if (existing != null && _version(existing) >= _version(feature)) return;
    }
    await _storeFeatures([
      ...?stored?.where((f) => f.id != feature.id),
      feature,
    ]);
  }

  Future<void> _deleteFeature(FeatureState feature) async {
    final stored = await _readFeatures();
    if (stored == null || !stored.any((f) => f.id == feature.id)) return;
    await _storeFeatures(stored.where((f) => f.id != feature.id).toList());
  }
}
