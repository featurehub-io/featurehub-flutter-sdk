import 'dart:async';
import 'dart:io' show Platform;

import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:logging/logging.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/feature_provider.dart';
import 'package:openfeature_dart_server_sdk/provider_capabilities.dart';
import 'package:openfeature_dart_server_sdk/provider_lifecycle.dart';

final _log = Logger('featurehub_openfeature_server');

/// The FeatureHub provider for the OpenFeature Dart server SDK.
///
/// The provider keeps the whole feature bundle of one FeatureHub environment
/// in a local repository, kept up to date by streaming (the default), polling
/// or passive refresh, and resolves every flag from it: there is never a
/// network call per flag.
///
/// - **Client-evaluated API keys** (containing `*`, recommended for servers):
///   every feature's rollout strategies are delivered, and each resolution is
///   evaluated locally against its own evaluation context, so concurrent
///   requests for different users are independent.
/// - **Server-evaluated API keys**: FeatureHub Edge evaluates the bundle for a
///   single context. When a resolution's context differs from the current one
///   the bundle is re-fetched for it, and resolutions are serialised so they
///   never see another context's bundle. Prefer a client-evaluated key for
///   multi-user workloads.
///
/// The OpenFeature `targetingKey` is FeatureHub's `userkey`; see
/// [mapEvaluationContext] for how other attributes are mapped.
class FeatureHubProvider
    implements Provider, ProviderInitialization, ProviderShutdown {
  /// The FeatureHub Edge URL, e.g. `https://edge.example.com`.
  final String host;

  /// The environment's SDK API key.
  final String apiKey;

  final FeatureHubUpdateMode mode;

  /// For [FeatureHubUpdateMode.polling], how often to poll; for
  /// [FeatureHubUpdateMode.passive], how old the features may get before a
  /// resolution refreshes them. Null when streaming.
  final Duration? pollInterval;

  /// How long initialization (and, for server-evaluated keys, a context
  /// change) waits for features.
  final Duration waitForReady;

  final ReconnectPolicy reconnectPolicy;

  /// How long establishing an HTTP connection may take (null: indefinitely).
  final Duration? connectTimeout;

  /// How long a polling request may take, or how long a streaming connection
  /// attempt waits for the stream to open (null: indefinitely). A streaming
  /// attempt that times out is retried according to [reconnectPolicy].
  final Duration? requestTimeout;

  /// True if [apiKey] is client-evaluated.
  final bool clientEvaluated;

  /// Stores that keep a copy of the features (see [FeatureStore]),
  /// attached before connecting to FeatureHub, so the features they hold are
  /// available straight away.
  final List<FeatureStore> stores;

  final FeatureHubConnection Function(FeatureHubProvider provider)?
  _connectionFactory;

  // synchronous, as OpenFeature requires the READY/ERROR event to be delivered
  // before initializeProvider returns
  final _events = StreamController<ProviderLifecycleEvent>.broadcast(
    sync: true,
  );
  FeatureHubConnection? _connection;
  ProviderStateTracker? _tracker;
  bool _ready = false;

  /// Serialises server-evaluated resolutions (see the class documentation).
  Future<void> _lock = Future.value();

  /// The environment variable read for [host] when it is not given.
  static const edgeUrlVariable = 'FEATUREHUB_EDGE_URL';

  /// The environment variable read for a client-evaluated [apiKey] when none
  /// is given; preferred over [serverApiKeyVariable].
  static const clientApiKeyVariable = 'FEATUREHUB_CLIENT_API_KEY';

  /// The environment variable read for a server-evaluated [apiKey] when none
  /// is given and [clientApiKeyVariable] is not set.
  static const serverApiKeyVariable = 'FEATUREHUB_SERVER_API_KEY';

  /// The environment variable read for [pollInterval] (in seconds) when it is
  /// not given. If set, the provider polls rather than streams.
  static const pollIntervalVariable = 'FEATUREHUB_POLL_INTERVAL';

  /// Creates the provider. Anything not given is read from the environment:
  ///
  /// - [host] from `FEATUREHUB_EDGE_URL`;
  /// - [apiKey] from `FEATUREHUB_CLIENT_API_KEY`, or if that is not set
  ///   `FEATUREHUB_SERVER_API_KEY`;
  /// - [pollInterval] from `FEATUREHUB_POLL_INTERVAL` (seconds).
  ///
  /// Unless [mode] is given, the provider polls every [pollInterval] if there
  /// is one, and otherwise streams. Polling and passive modes require a
  /// [pollInterval].
  ///
  /// Throws an [ArgumentError] if there is no host or API key, or if the poll
  /// interval is invalid or missing for polling. [environment] replaces the
  /// process environment (for tests), and [connectionFactory] the connection
  /// to FeatureHub (for tests).
  factory FeatureHubProvider({
    String? host,
    String? apiKey,
    FeatureHubUpdateMode? mode,
    Duration? pollInterval,
    Duration waitForReady = const Duration(seconds: 10),
    ReconnectPolicy reconnectPolicy = const ReconnectPolicy(),
    Duration? connectTimeout,
    Duration? requestTimeout,
    bool catchAndReleaseMode = false,
    List<FeatureStore> stores = const [],
    Map<String, String>? environment,
    FeatureHubConnection Function(FeatureHubProvider provider)?
    connectionFactory,
  }) {
    final env = environment ?? Platform.environment;
    String? setting(String name) {
      final value = env[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final resolvedHost = _nonEmpty(host) ?? setting(edgeUrlVariable);
    if (resolvedHost == null) {
      throw ArgumentError(
        'FeatureHubProvider requires a host, or $edgeUrlVariable to be set',
        'host',
      );
    }

    final resolvedKey =
        _nonEmpty(apiKey) ??
        setting(clientApiKeyVariable) ??
        setting(serverApiKeyVariable);
    if (resolvedKey == null) {
      throw ArgumentError(
        'FeatureHubProvider requires an apiKey, or $clientApiKeyVariable or '
            '$serverApiKeyVariable to be set',
        'apiKey',
      );
    }

    var interval = pollInterval;
    if (interval == null) {
      final seconds = setting(pollIntervalVariable);
      if (seconds != null) {
        final parsed = int.tryParse(seconds);
        if (parsed == null || parsed <= 0) {
          throw ArgumentError(
            '$pollIntervalVariable must be a positive number of seconds, not '
            '"$seconds"',
          );
        }
        interval = Duration(seconds: parsed);
      }
    }

    final resolvedMode =
        mode ??
        (interval == null
            ? FeatureHubUpdateMode.streaming
            : FeatureHubUpdateMode.polling);
    if (resolvedMode != FeatureHubUpdateMode.streaming && interval == null) {
      throw ArgumentError(
        '${resolvedMode.name} mode requires a pollInterval, or '
            '$pollIntervalVariable to be set',
        'pollInterval',
      );
    }

    return FeatureHubProvider._(
      host: resolvedHost,
      apiKey: resolvedKey,
      mode: resolvedMode,
      pollInterval: resolvedMode == FeatureHubUpdateMode.streaming
          ? null
          : interval,
      waitForReady: waitForReady,
      reconnectPolicy: reconnectPolicy,
      connectTimeout: connectTimeout,
      requestTimeout: requestTimeout,
      catchAndReleaseMode: catchAndReleaseMode,
      stores: stores,
      connectionFactory: connectionFactory,
    );
  }

  FeatureHubProvider._({
    required this.host,
    required this.apiKey,
    required this.mode,
    required this.pollInterval,
    required this.waitForReady,
    required this.reconnectPolicy,
    required this.connectTimeout,
    required this.requestTimeout,
    required this._catchAndReleaseMode,
    required this.stores,
    required this._connectionFactory,
  }) : clientEvaluated = FeatureHubConfig.isClientEvaluatedKeys([apiKey]);

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  @override
  ProviderMetadata get metadata => const ProviderMetadata(name: 'featurehub');

  @override
  Stream<ProviderLifecycleEvent> get providerEvents => _events.stream;

  /// The repository features are resolved from, once initialized.
  ClientFeatureRepository? get repository => _connection?.repository;

  bool _catchAndReleaseMode;

  /// Catch and release mode: feature updates are held back until [release]
  /// is called (see [ClientFeatureRepository.catchAndReleaseMode]). It takes
  /// effect once the initial features have arrived, so it can be switched on
  /// when the provider is created. Changes are announced as configuration
  /// changed events when they are released.
  bool get catchAndReleaseMode =>
      repository?.catchAndReleaseMode ?? _catchAndReleaseMode;

  set catchAndReleaseMode(bool value) {
    _catchAndReleaseMode = value;
    repository?.catchAndReleaseMode = value;
  }

  /// In catch and release mode, applies the feature updates held back so
  /// far. Does nothing before initialization.
  Future<void> release() => repository?.release() ?? Future.value();

  void _emit(
    ProviderLifecycleEventType type,
    String message, {
    ErrorCode? errorCode,
    List<String>? flagsChanged,
  }) {
    if (_events.isClosed) return;
    _events.add(
      ProviderLifecycleEvent(
        type,
        message,
        errorCode: errorCode,
        flagsChanged: flagsChanged,
      ),
    );
  }

  @override
  Future<void> initializeProvider(
    EvaluationContext context, {
    String? domain,
  }) async {
    final connection =
        _connectionFactory?.call(this) ??
        FeatureHubConnection(
          host: host,
          apiKey: apiKey,
          mode: mode,
          // only used when polling, which always has an interval
          pollInterval: pollInterval ?? Duration.zero,
          reconnectPolicy: reconnectPolicy,
          connectTimeout: connectTimeout,
          requestTimeout: requestTimeout,
        );
    _connection = connection;
    connection.repository.catchAndReleaseMode = _catchAndReleaseMode;
    // stores first, so the features they hold are available straight away
    for (final store in stores) {
      try {
        await store.attach(
          FeatureStoreTarget(
            repository: connection.repository,
            host: host,
            apiKey: apiKey,
          ),
        );
      } catch (e, s) {
        _log.warning('A FeatureHub store failed to attach', e, s);
      }
    }

    MappedContext? initialContext;
    if (!clientEvaluated) {
      try {
        initialContext = mapEvaluationContext(context.toProviderContext());
      } on InvalidContextException catch (e) {
        _emit(
          ProviderLifecycleEventType.PROVIDER_ERROR,
          e.message,
          errorCode: ErrorCode.INVALID_CONTEXT,
        );
        throw ProviderException(e.message, code: ErrorCode.INVALID_CONTEXT);
      }
    }

    await connection.start(context: initialContext);
    final readiness = await connection.waitForReady(waitForReady);

    if (readiness != Readyness.Ready) {
      final fatal = readiness == Readyness.Failed;
      final message = fatal
          ? 'FeatureHub rejected the API key, or the environment does not exist.'
          : 'FeatureHub did not become ready within $waitForReady.';
      _emit(
        ProviderLifecycleEventType.PROVIDER_ERROR,
        message,
        errorCode: fatal ? ErrorCode.PROVIDER_FATAL : ErrorCode.GENERAL,
      );
      await connection.close();
      _connection = null;
      throw ProviderException(
        message,
        code: fatal ? ErrorCode.PROVIDER_FATAL : ErrorCode.GENERAL,
      );
    }

    _ready = true;
    _emit(ProviderLifecycleEventType.PROVIDER_READY, 'FeatureHub is ready');

    _tracker = ProviderStateTracker(
      connection.repository,
      onStale: () => _emit(
        ProviderLifecycleEventType.PROVIDER_STALE,
        'Lost the connection to FeatureHub; features may be out of date',
      ),
      onRecovered: () => _emit(
        ProviderLifecycleEventType.PROVIDER_READY,
        'FeatureHub is ready',
      ),
      onFatal: () {
        _ready = false;
        _emit(
          ProviderLifecycleEventType.PROVIDER_ERROR,
          'FeatureHub rejected the API key, or the environment no longer exists',
          errorCode: ErrorCode.PROVIDER_FATAL,
        );
      },
      onFlagsChanged: (keys) => _emit(
        ProviderLifecycleEventType.PROVIDER_CONFIGURATION_CHANGED,
        'FeatureHub features changed',
        flagsChanged: keys,
      ),
    );
  }

  @override
  Future<void> shutdownProvider() async {
    _ready = false;
    await _tracker?.cancel();
    _tracker = null;
    final connection = _connection;
    _connection = null;
    await connection?.close();
    for (final store in stores) {
      await store.close();
    }
  }

  @override
  Future<FlagEvaluationResult<bool>> getBooleanFlag(
    String flagKey,
    bool defaultValue, {
    Map<String, dynamic>? context,
  }) => _resolve(flagKey, FeatureKind.boolean, defaultValue, context);

  @override
  Future<FlagEvaluationResult<String>> getStringFlag(
    String flagKey,
    String defaultValue, {
    Map<String, dynamic>? context,
  }) => _resolve(flagKey, FeatureKind.string, defaultValue, context);

  @override
  Future<FlagEvaluationResult<int>> getIntegerFlag(
    String flagKey,
    int defaultValue, {
    Map<String, dynamic>? context,
  }) => _resolve(flagKey, FeatureKind.integer, defaultValue, context);

  @override
  Future<FlagEvaluationResult<double>> getDoubleFlag(
    String flagKey,
    double defaultValue, {
    Map<String, dynamic>? context,
  }) => _resolve(flagKey, FeatureKind.double, defaultValue, context);

  @override
  Future<FlagEvaluationResult<Map<String, dynamic>>> getObjectFlag(
    String flagKey,
    Map<String, dynamic> defaultValue, {
    Map<String, dynamic>? context,
  }) => _resolve(flagKey, FeatureKind.object, defaultValue, context);

  Future<FlagEvaluationResult<T>> _resolve<T>(
    String flagKey,
    FeatureKind kind,
    T defaultValue,
    Map<String, dynamic>? context,
  ) async {
    final connection = _connection;
    final FeatureHubResolution<T> resolution;

    if (connection == null || !_ready) {
      resolution = connection?.repository.readyness == Readyness.Failed
          ? fatalResolution(defaultValue)
          : notReadyResolution(defaultValue);
    } else {
      try {
        final mapped = mapEvaluationContext(context);
        await connection.refreshIfStale();
        final evaluation = clientEvaluated
            ? connection.repository.evaluate(
                flagKey,
                context: mapped.strategyContext,
              )
            : await _serverEvaluated(connection, flagKey, mapped);
        resolution = resolveFromEvaluation(
          flagKey,
          kind,
          defaultValue,
          evaluation,
        );
      } on InvalidContextException catch (e) {
        return _result(flagKey, invalidContextResolution(defaultValue, e));
      } catch (e, s) {
        _log.warning("FeatureHub evaluation of '$flagKey' failed", e, s);
        return _result(flagKey, generalErrorResolution(defaultValue, e));
      }
    }

    return _result(flagKey, resolution);
  }

  /// Server-evaluated keys: switches the shared context if needed and reads
  /// the feature, serialised with every other server-evaluated resolution.
  Future<EvaluatedFeature> _serverEvaluated(
    FeatureHubConnection connection,
    String flagKey,
    MappedContext context,
  ) {
    final run = _lock.then((_) async {
      final readiness = await connection.setContext(context, waitForReady);
      if (readiness == Readyness.Failed) {
        throw StateError(
          'FeatureHub failed to refresh the features for the new context',
        );
      }
      return connection.repository.evaluate(flagKey);
    });
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  FlagEvaluationResult<T> _result<T>(
    String flagKey,
    FeatureHubResolution<T> resolution,
  ) => FlagEvaluationResult<T>(
    flagKey: flagKey,
    value: resolution.value,
    reason: resolution.reason,
    variant: resolution.variant,
    errorCode: _errorCode(resolution.errorCode),
    errorMessage: resolution.errorMessage,
    flagMetadata: resolution.flagMetadata,
    evaluatedAt: DateTime.now(),
    evaluatorId: metadata.name,
  );

  static ErrorCode? _errorCode(ResolutionErrorCode? code) => switch (code) {
    null => null,
    ResolutionErrorCode.providerNotReady => ErrorCode.PROVIDER_NOT_READY,
    ResolutionErrorCode.providerFatal => ErrorCode.PROVIDER_FATAL,
    ResolutionErrorCode.flagNotFound => ErrorCode.FLAG_NOT_FOUND,
    ResolutionErrorCode.typeMismatch => ErrorCode.TYPE_MISMATCH,
    ResolutionErrorCode.parseError => ErrorCode.PARSE_ERROR,
    ResolutionErrorCode.invalidContext => ErrorCode.INVALID_CONTEXT,
    ResolutionErrorCode.general => ErrorCode.GENERAL,
  };
}
