import 'dart:async';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:http/http.dart' as http;
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
///   single context, so the provider serves a **single user** and cannot be
///   shared between users: it is intended for apps, browsers and batch
///   processes. Where the context switches (e.g. a server handling requests
///   for different users), a client-evaluated key must be used. If the
///   context does change, the bundle is re-fetched for it; if that fails or
///   times out, resolutions use the previous context's bundle.
///
/// With a [featuresUrl] instead of a host and API key, the provider never
/// connects to FeatureHub: it polls (or passively refreshes) the features from
/// another server's API (see [FeatureSnapshotClient]). By default no context
/// is sent: the server gives the features with their rollout strategies, and
/// each resolution evaluates them against its own context, as for a
/// client-evaluated key. With [sendContext] the server evaluates them for one
/// context, as for a server-evaluated key. With none of these the features
/// come from the [stores] alone.
///
/// The OpenFeature `targetingKey` is FeatureHub's `userkey`; see
/// [mapEvaluationContext] for how other attributes are mapped.
class FeatureHubProvider
    implements Provider, ProviderInitialization, ProviderShutdown {
  /// The FeatureHub Edge URL, e.g. `https://edge.example.com`, or null if
  /// the provider does not connect to FeatureHub.
  final String? host;

  /// The environment's SDK API key, or null if the provider does not connect
  /// to FeatureHub.
  final String? apiKey;

  /// Another server's features API, polled instead of FeatureHub (see
  /// [FeatureSnapshotClient]), or null.
  final String? featuresUrl;

  /// With a [featuresUrl] or a [transportFactory] (and no API key): true to
  /// send the evaluation context, so the source evaluates the features for
  /// it (serving a single context, as a server-evaluated key does); false
  /// (the default) to evaluate their rollout strategies locally for each
  /// resolution.
  final bool sendContext;

  /// Headers sent with every request, for example for a proxy, gateway or
  /// authentication: to FeatureHub (streaming and polling) and to
  /// [featuresUrl]. A [transportFactory]'s transport is given them too.
  final Map<String, String> headers;

  /// Makes the polling requests (to FeatureHub or [featuresUrl]), for example
  /// configured with a proxy. By default one is created.
  final Dio? dio;

  /// Makes the streaming connections, for example configured with a proxy.
  /// By default one is created.
  final http.Client? httpClient;

  /// Creates your own transport, replacing the built-in ones: over
  /// WebSockets, another SSE client, or anything else (see
  /// [FeatureHubTransport] for what it has to do).
  final FeatureHubTransportFactory? transportFactory;

  final FeatureHubUpdateMode mode;

  /// For [FeatureHubUpdateMode.polling], how often to poll; for
  /// [FeatureHubUpdateMode.passive], how old the features may get before a
  /// resolution refreshes them. Null when streaming.
  final Duration? pollInterval;

  /// How long initialization (and, for server-evaluated keys, a context
  /// change) waits for features.
  final Duration waitForReady;

  /// How streaming reconnects: by default [defaultReconnectPolicy] (3s
  /// after a network error, 30s after a 5xx, doubling each consecutive
  /// failure up to 5 minutes; a 4xx stops). Every value is configurable.
  final ReconnectPolicy reconnectPolicy;

  /// How long establishing an HTTP connection may take (null: indefinitely).
  final Duration? connectTimeout;

  /// How long a polling request may take, or how long a streaming connection
  /// attempt waits for the stream to open (null: indefinitely). A streaming
  /// attempt that times out is retried according to [reconnectPolicy].
  final Duration? requestTimeout;

  /// True if features are evaluated locally for each context: [apiKey] is
  /// client-evaluated, a [featuresUrl] or [transportFactory] is used without
  /// [sendContext], or the features come from the stores alone.
  final bool clientEvaluated;

  /// Stores that keep a copy of the features (see [FeatureStore]),
  /// attached before connecting to FeatureHub, so the features they hold are
  /// available straight away.
  final List<FeatureStore> stores;

  /// Interceptors that supply feature values in place of FeatureHub's (see
  /// [ValueInterceptor]), for example local overrides during development. The first
  /// that matches a feature supplies its value; they also override locked
  /// features. They are closed when the provider shuts down.
  final List<ValueInterceptor> interceptors;

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
  /// With a [featuresUrl], the provider polls that server instead of
  /// FeatureHub (the host and API key are then not read from the
  /// environment), and needs a [pollInterval]. With none of these (given or
  /// in the environment), it gets its features from [stores] alone.
  ///
  /// Throws an [ArgumentError] if there is a host but no API key or the
  /// reverse, if a [featuresUrl] is given with them or with streaming, if
  /// there is nothing to get features from, or if the poll interval is
  /// invalid or missing for polling. [environment] replaces the
  /// process environment (for tests), and [connectionFactory] the connection
  /// to FeatureHub (for tests).
  factory FeatureHubProvider({
    String? host,
    String? apiKey,
    String? featuresUrl,
    bool sendContext = false,
    Map<String, String> headers = const {},
    Dio? dio,
    http.Client? httpClient,
    FeatureHubTransportFactory? transportFactory,
    FeatureHubUpdateMode? mode,
    Duration? pollInterval,
    Duration waitForReady = const Duration(seconds: 10),
    ReconnectPolicy reconnectPolicy = defaultReconnectPolicy,
    Duration? connectTimeout,
    Duration? requestTimeout,
    bool catchAndReleaseMode = false,
    List<FeatureStore> stores = const [],
    List<ValueInterceptor> interceptors = const [],
    Map<String, String>? environment,
    FeatureHubConnection Function(FeatureHubProvider provider)?
    connectionFactory,
  }) {
    final env = environment ?? Platform.environment;
    String? setting(String name) {
      final value = env[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final resolvedUrl = _nonEmpty(featuresUrl);
    if (resolvedUrl != null &&
        (_nonEmpty(host) != null || _nonEmpty(apiKey) != null)) {
      throw ArgumentError(
        'FeatureHubProvider takes a featuresUrl or a host and apiKey, not both',
        'featuresUrl',
      );
    }
    // with a featuresUrl, FeatureHub settings in the environment are ignored
    final resolvedHost = resolvedUrl != null
        ? null
        : _nonEmpty(host) ?? setting(edgeUrlVariable);
    final resolvedKey = resolvedUrl != null
        ? null
        : _nonEmpty(apiKey) ??
              setting(clientApiKeyVariable) ??
              setting(serverApiKeyVariable);
    if (resolvedHost == null && resolvedKey == null) {
      if (resolvedUrl == null && transportFactory == null && stores.isEmpty) {
        throw ArgumentError(
          'FeatureHubProvider requires a host and an apiKey (or '
              '$edgeUrlVariable and $clientApiKeyVariable or '
              '$serverApiKeyVariable to be set), a featuresUrl, a '
              'transportFactory, or stores to get its features from',
          'host',
        );
      }
    } else if (resolvedHost == null) {
      throw ArgumentError(
        'FeatureHubProvider requires a host, or $edgeUrlVariable to be set',
        'host',
      );
    } else if (resolvedKey == null) {
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
        (interval == null && resolvedUrl == null
            ? FeatureHubUpdateMode.streaming
            : FeatureHubUpdateMode.polling);
    if (resolvedUrl != null &&
        transportFactory == null &&
        resolvedMode == FeatureHubUpdateMode.streaming) {
      throw ArgumentError(
        'Features from a featuresUrl are polled: use the polling or passive '
            'mode',
        'mode',
      );
    }
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
      featuresUrl: resolvedUrl,
      sendContext: sendContext,
      headers: headers,
      dio: dio,
      httpClient: httpClient,
      transportFactory: transportFactory,
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
      interceptors: interceptors,
      connectionFactory: connectionFactory,
    );
  }

  FeatureHubProvider._({
    required this.host,
    required this.apiKey,
    required this.featuresUrl,
    required this.sendContext,
    required this.headers,
    required this.dio,
    required this.httpClient,
    required this.transportFactory,
    required this.mode,
    required this.pollInterval,
    required this.waitForReady,
    required this.reconnectPolicy,
    required this.connectTimeout,
    required this.requestTimeout,
    required this._catchAndReleaseMode,
    required this.stores,
    required this.interceptors,
    required this._connectionFactory,
  }) : clientEvaluated = apiKey != null
           ? FeatureHubConfig.isClientEvaluatedKeys([apiKey])
           : featuresUrl != null || transportFactory != null
           ? !sendContext
           : true;

  /// True if the provider connects to FeatureHub (it has a [host] and an
  /// [apiKey]).
  bool get connectsToFeatureHub => host != null;

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
    // check the context first, so nothing is started for an invalid one
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

    final connection =
        _connectionFactory?.call(this) ??
        FeatureHubConnection(
          host: host,
          apiKey: apiKey,
          featuresUrl: featuresUrl,
          sendContext: sendContext,
          headers: headers,
          dio: dio,
          httpClient: httpClient,
          transportFactory: transportFactory,
          mode: mode,
          // only used when polling, which always has an interval
          pollInterval: pollInterval ?? Duration.zero,
          reconnectPolicy: reconnectPolicy,
          connectTimeout: connectTimeout,
          requestTimeout: requestTimeout,
        );
    _connection = connection;
    connection.repository.catchAndReleaseMode = _catchAndReleaseMode;
    for (final interceptor in interceptors) {
      connection.repository.addValueInterceptor(interceptor);
    }
    // stores first, so the features they hold are available straight away
    for (final store in stores) {
      try {
        await store.attach(
          FeatureStoreTarget(
            repository: connection.repository,
            host: host,
            apiKey: apiKey,
            featuresUrl: featuresUrl,
          ),
        );
      } catch (e, s) {
        _log.warning('A FeatureHub store failed to attach', e, s);
      }
    }

    await connection.start(context: initialContext);
    final readiness = await connection.waitForReady(waitForReady);

    if (readiness != Readyness.Ready) {
      final fatal = readiness == Readyness.Failed;
      final message = fatal
          ? _rejected(connection)
          : '${connection.sourceDescription} did not become ready within '
                '$waitForReady.';
      _emit(
        ProviderLifecycleEventType.PROVIDER_ERROR,
        message,
        errorCode: fatal ? ErrorCode.PROVIDER_FATAL : ErrorCode.GENERAL,
      );
      await connection.close();
      _connection = null;
      await _closeStores();
      throw ProviderException(
        message,
        code: fatal ? ErrorCode.PROVIDER_FATAL : ErrorCode.GENERAL,
      );
    }

    _ready = true;
    _emit(ProviderLifecycleEventType.PROVIDER_READY, 'FeatureHub is ready');

    _tracker = ProviderStateTracker(
      connection.repository,
      // a permanent stop after features: keep resolving from the last ones
      onStale: (cause) =>
          _emit(ProviderLifecycleEventType.PROVIDER_STALE, switch (cause) {
            StaleCause.environmentStale =>
              'The FeatureHub environment is stale: features will not be '
                  'updated again',
            StaleCause.connectionFailed =>
              '${_rejected(connection)} Features will not be updated again.',
          }),
      onFlagsChanged: (keys) => _emit(
        ProviderLifecycleEventType.PROVIDER_CONFIGURATION_CHANGED,
        'FeatureHub features changed',
        flagsChanged: keys,
      ),
    );
  }

  static String _rejected(FeatureHubConnection connection) =>
      connection.connectsToFeatureHub
      ? 'FeatureHub rejected the API key, or the environment does not exist.'
      : '${connection.sourceDescription} rejected the request.';

  Future<void> _closeStores() async {
    for (final store in stores) {
      try {
        await store.close();
      } catch (e, s) {
        _log.warning('A FeatureHub store failed to close', e, s);
      }
    }
  }

  @override
  Future<void> shutdownProvider() async {
    _ready = false;
    await _tracker?.cancel();
    _tracker = null;
    final connection = _connection;
    _connection = null;
    await connection?.close();
    await _closeStores();
    for (final interceptor in interceptors) {
      interceptor.close();
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
      // once the source has stopped for good (stale), nothing can be fetched
      // for a new context: the last features are used; likewise if it fails
      // for good while fetching
      if (_tracker?.stale != true) {
        await connection.setContext(context, waitForReady);
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
