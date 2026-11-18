import 'dart:async';

import 'package:dio/dio.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    as fh;
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:openfeature_dart_client_sdk/openfeature_dart_client_sdk.dart';

final _log = Logger('featurehub_openfeature_client');

/// The FeatureHub provider for the OpenFeature Dart client SDK, for Flutter
/// (Android, iOS) and browser applications.
///
/// The provider keeps the whole feature bundle of one FeatureHub environment
/// in a local repository, kept up to date by streaming (the default: native
/// `EventSource` in browsers, `featurehub_sse_client` elsewhere), polling or
/// passive refresh, and resolves every flag synchronously from it.
///
/// - **Server-evaluated API keys** (recommended for applications, since a
///   client-evaluated key exposes every rollout strategy to the device):
///   FeatureHub Edge evaluates the bundle for the application's evaluation
///   context. When the context changes the provider reports `reconciling`
///   and fetches the bundle for the new context.
/// - **Client-evaluated API keys** (containing `*`): every feature's rollout
///   strategies are delivered and evaluated locally, so a context change
///   needs no network request.
///
/// With a [featuresUrl] instead of a [host] and [apiKey], the provider never
/// connects to FeatureHub: it polls (or passively refreshes) the features from
/// your own server's API (see [fh.FeatureSnapshotClient]). With [sendContext]
/// (the default) the server evaluates them for the application's context, so
/// neither a FeatureHub key nor the rollout strategies reach the device, and a
/// context change reconciles as for a server-evaluated key. With none of
/// these the features come from the [stores] alone.
///
/// The OpenFeature `targetingKey` is FeatureHub's `userkey`; see
/// [fh.mapEvaluationContext] for how other attributes are mapped.
final class FeatureHubProvider
    implements
        FeatureProvider,
        InitializableProvider,
        ShutdownProvider,
        ContextReconciliationProvider,
        ProviderEventSource {
  /// The FeatureHub Edge URL, e.g. `https://edge.example.com`, or null if
  /// the provider does not connect to FeatureHub.
  final String? host;

  /// The environment's SDK API key, or null if the provider does not connect
  /// to FeatureHub.
  final String? apiKey;

  /// Your own server's features API, polled instead of FeatureHub (see
  /// [fh.FeatureSnapshotClient]), or null.
  final String? featuresUrl;

  /// With a [featuresUrl] or a [transportFactory] (and no API key): true to
  /// send the evaluation context, so the source evaluates the features for
  /// it; false to evaluate their rollout strategies locally.
  final bool sendContext;

  /// Headers sent with every request, for example for a proxy, gateway or
  /// authentication: to FeatureHub (polling, and streaming except in
  /// browsers, whose `EventSource` cannot send headers) and to
  /// [featuresUrl]. A [transportFactory]'s transport is given them too.
  final Map<String, String> headers;

  /// Makes the polling requests (to FeatureHub or [featuresUrl]), for example
  /// configured with a proxy. By default one is created.
  final Dio? dio;

  /// Makes the streaming connections on Android and iOS (`dart:io`), for
  /// example configured with a proxy. By default one is created. Browsers
  /// use their own `EventSource`.
  final http.Client? httpClient;

  /// Creates your own transport, replacing the built-in ones: over
  /// WebSockets, another SSE client, or anything else (see
  /// [fh.FeatureHubTransport] for what it has to do).
  final fh.FeatureHubTransportFactory? transportFactory;

  /// Streaming by default, or polling with a [featuresUrl].
  final fh.FeatureHubUpdateMode mode;

  /// For [fh.FeatureHubUpdateMode.activePolling], how often to poll; for
  /// [fh.FeatureHubUpdateMode.passivePolling], how old the features may get before a
  /// resolution refreshes them (in the background).
  final Duration pollInterval;

  /// How long initialization and a context change wait for features.
  final Duration waitForReady;

  /// How streaming reconnects: by default [fh.defaultReconnectPolicy] (3s
  /// after a network error, 30s after a 5xx, doubling each consecutive
  /// failure up to 5 minutes; a 4xx stops). Every value is configurable. In
  /// browsers the native `EventSource` reconnects after a dropped
  /// connection, but a connection error is final: before any features the
  /// provider fails to initialize, after them it goes stale for good.
  final ReconnectPolicy reconnectPolicy;

  /// How long establishing an HTTP connection may take (null: indefinitely).
  /// In browsers this applies only to polling, since the browser controls
  /// `EventSource` connections.
  final Duration? connectTimeout;

  /// How long a polling request may take, or how long a streaming connection
  /// attempt waits for the stream to open (null: indefinitely). A streaming
  /// attempt that times out is retried according to [reconnectPolicy].
  final Duration? requestTimeout;

  /// True if features are evaluated locally for each context: [apiKey] is
  /// client-evaluated, a [featuresUrl] or [transportFactory] is used without
  /// [sendContext], or the features come from the stores alone.
  final bool clientEvaluated;

  /// Stores that keep a copy of the features (see [fh.FeatureStore]),
  /// attached before connecting to FeatureHub, so the features they hold are
  /// available straight away.
  final List<fh.FeatureStore> stores;

  /// Interceptors that supply feature values in place of FeatureHub's (see
  /// [fh.ValueInterceptor]), for example local overrides during development. The first
  /// that matches a feature supplies its value; they also override locked
  /// features. They are closed when the provider shuts down.
  final List<fh.ValueInterceptor> interceptors;

  final fh.FeatureHubConnection Function(FeatureHubProvider provider)?
  _connectionFactory;

  // synchronous: OpenFeature completes initialization and reconciliation on
  // the terminal event, which must arrive before those calls return
  final _events = StreamController<ProviderEvent>.broadcast(sync: true);
  fh.FeatureHubConnection? _connection;
  fh.ProviderStateTracker? _tracker;
  bool _ready = false;

  /// Give both [host] and [apiKey] to connect to FeatureHub, or a
  /// [featuresUrl] to poll your own server, or a [transportFactory] for your
  /// own transport, or none of these to get the features from [stores] alone.
  /// Throws an [ArgumentError] if only one of [host] and [apiKey] is given
  /// (an empty string counts as not given), if a [featuresUrl] is given with
  /// them, or with streaming and no [transportFactory], or if there is
  /// nothing to get features from. [connectionFactory] replaces the whole
  /// connection (for tests).
  FeatureHubProvider({
    String? host,
    String? apiKey,
    String? featuresUrl,
    this.sendContext = true,
    this.headers = const {},
    this.dio,
    this.httpClient,
    this.transportFactory,
    fh.FeatureHubUpdateMode? mode,
    this.pollInterval = const Duration(seconds: 30),
    this.waitForReady = const Duration(seconds: 10),
    this.reconnectPolicy = fh.defaultReconnectPolicy,
    this.connectTimeout,
    this.requestTimeout,
    this._catchAndReleaseMode = false,
    this.stores = const [],
    this.interceptors = const [],
    this._connectionFactory,
  }) : host = _nonEmpty(host),
       apiKey = _nonEmpty(apiKey),
       featuresUrl = _nonEmpty(featuresUrl),
       mode =
           mode ??
           (_nonEmpty(featuresUrl) == null
               ? fh.FeatureHubUpdateMode.streaming
               : fh.FeatureHubUpdateMode.activePolling),
       clientEvaluated = _nonEmpty(apiKey) != null
           ? fh.isClientEvaluatedKeys([apiKey!.trim()])
           : _nonEmpty(featuresUrl) != null || transportFactory != null
           ? !sendContext
           : true {
    if ((this.host == null) != (this.apiKey == null)) {
      throw ArgumentError(
        'FeatureHubProvider requires both a host and an apiKey, or neither',
        this.host == null ? 'host' : 'apiKey',
      );
    }
    if (this.featuresUrl != null) {
      if (this.host != null) {
        throw ArgumentError(
          'FeatureHubProvider takes a featuresUrl or a host and apiKey, not '
              'both',
          'featuresUrl',
        );
      }
      if (this.mode == fh.FeatureHubUpdateMode.streaming &&
          transportFactory == null) {
        throw ArgumentError(
          'Features from a featuresUrl are polled: use activePolling or '
              'passivePolling',
          'mode',
        );
      }
    }
    if (this.mode != fh.FeatureHubUpdateMode.streaming) {
      // zero polls once; otherwise at least 5 seconds
      fh.validatePollInterval(pollInterval);
    }
    if (this.host == null &&
        this.featuresUrl == null &&
        transportFactory == null &&
        stores.isEmpty) {
      throw ArgumentError(
        'FeatureHubProvider requires a host and an apiKey, a featuresUrl, a '
            'transportFactory, or stores to get its features from',
        'host',
      );
    }
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  /// True if the provider connects to FeatureHub (it has a [host] and an
  /// [apiKey]).
  bool get connectsToFeatureHub => host != null;

  @override
  ProviderMetadata get metadata => const ProviderMetadata(name: 'featurehub');

  @override
  Stream<ProviderEvent> get events => _events.stream;

  /// The repository features are resolved from, once initialized.
  fh.ClientFeatureRepository? get repository => _connection?.repository;

  bool _catchAndReleaseMode;

  /// Catch and release mode: feature updates are held back until [release]
  /// is called (see [fh.ClientFeatureRepository.catchAndReleaseMode]). It takes
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
    ProviderEventType type, {
    String? message,
    ErrorCode? errorCode,
    List<String> flagsChanged = const [],
  }) {
    if (_events.isClosed) return;
    _events.add(
      ProviderEvent(
        type: type,
        message: message,
        errorCode: errorCode,
        flagsChanged: flagsChanged,
      ),
    );
  }

  static Map<String, Object?> _contextMap(EvaluationContext context) =>
      context.asMap();

  @override
  Future<void> initialize(EvaluationContext context, {String? domain}) async {
    // check the context first, so nothing is started for an invalid one
    fh.MappedContext? initialContext;
    if (!clientEvaluated) {
      try {
        initialContext = fh.mapEvaluationContext(_contextMap(context));
      } on fh.InvalidContextException catch (e) {
        _emit(
          ProviderEventType.error,
          message: e.message,
          errorCode: ErrorCode.invalidContext,
        );
        return;
      }
    }

    final connection =
        _connectionFactory?.call(this) ??
        fh.FeatureHubConnection(
          host: host,
          apiKey: apiKey,
          featuresUrl: featuresUrl,
          sendContext: sendContext,
          headers: headers,
          dio: dio,
          httpClient: httpClient,
          transportFactory: transportFactory,
          mode: mode,
          pollInterval: pollInterval,
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
          fh.FeatureStoreTarget(
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

    if (readiness != fh.Readyness.Ready) {
      final fatal = readiness == fh.Readyness.Failed;
      _emit(
        ProviderEventType.error,
        message: fatal
            ? _rejected(connection)
            : '${connection.sourceDescription} did not become ready within '
                  '$waitForReady.',
        errorCode: fatal ? ErrorCode.providerFatal : ErrorCode.general,
      );
      await connection.close();
      _connection = null;
      await _closeStores();
      return;
    }

    _ready = true;
    _tracker = fh.ProviderStateTracker(
      connection.repository,
      // a permanent stop after features: keep resolving from the last ones
      onStale: (cause) => _emit(
        ProviderEventType.stale,
        message: _staleMessage(connection, cause),
      ),
      onFlagsChanged: (keys) =>
          _emit(ProviderEventType.configurationChanged, flagsChanged: keys),
    );
    _emit(ProviderEventType.ready);
  }

  @override
  Future<void> onContextChanged(
    EvaluationContext previousContext,
    EvaluationContext newContext,
  ) async {
    final connection = _connection;
    if (clientEvaluated || connection == null || _tracker?.stale == true) {
      // client-evaluated features are evaluated against each new context;
      // once the source has stopped for good, the last features are kept
      _emit(ProviderEventType.contextChanged);
      return;
    }

    final fh.MappedContext mapped;
    try {
      mapped = fh.mapEvaluationContext(_contextMap(newContext));
    } on fh.InvalidContextException catch (e) {
      _emit(
        ProviderEventType.error,
        message: e.message,
        errorCode: ErrorCode.invalidContext,
      );
      return;
    }

    _emit(ProviderEventType.reconciling);
    // if the source fails for good meanwhile, the provider goes stale and
    // keeps the last features
    await connection.setContext(mapped, waitForReady);
    _emit(ProviderEventType.contextChanged);
  }

  static String _staleMessage(
    fh.FeatureHubConnection connection,
    fh.StaleCause cause,
  ) => switch (cause) {
    fh.StaleCause.environmentStale =>
      'The FeatureHub environment is stale: features will not be updated '
          'again',
    fh.StaleCause.connectionFailed =>
      '${_rejected(connection)} Features will not be updated again.',
  };

  static String _rejected(fh.FeatureHubConnection connection) =>
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
  Future<void> shutdown() async {
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
  ResolutionDetails<bool> resolveBooleanValue(
    String flagKey,
    bool defaultValue,
    EvaluationContext context,
  ) => _resolve(flagKey, fh.FeatureKind.boolean, defaultValue, context);

  @override
  ResolutionDetails<String> resolveStringValue(
    String flagKey,
    String defaultValue,
    EvaluationContext context,
  ) => _resolve(flagKey, fh.FeatureKind.string, defaultValue, context);

  @override
  ResolutionDetails<int> resolveIntegerValue(
    String flagKey,
    int defaultValue,
    EvaluationContext context,
  ) => _resolve(flagKey, fh.FeatureKind.integer, defaultValue, context);

  @override
  ResolutionDetails<double> resolveDoubleValue(
    String flagKey,
    double defaultValue,
    EvaluationContext context,
  ) => _resolve(flagKey, fh.FeatureKind.double, defaultValue, context);

  @override
  ResolutionDetails<Map<String, Object?>> resolveStructureValue(
    String flagKey,
    Map<String, Object?> defaultValue,
    EvaluationContext context,
  ) => _resolve(flagKey, fh.FeatureKind.object, defaultValue, context);

  ResolutionDetails<T> _resolve<T>(
    String flagKey,
    fh.FeatureKind kind,
    T defaultValue,
    EvaluationContext context,
  ) {
    final connection = _connection;
    fh.FeatureHubResolution<T> resolution;

    if (connection == null || !_ready) {
      resolution = connection?.repository.readyness == fh.Readyness.Failed
          ? fh.fatalResolution(defaultValue)
          : fh.notReadyResolution(defaultValue);
    } else {
      try {
        if (mode == fh.FeatureHubUpdateMode.passivePolling) {
          // resolution is synchronous: refresh for the next one
          unawaited(connection.refreshIfStale());
        }
        // server-evaluated bundles are already evaluated for the context
        final evaluation = clientEvaluated
            ? connection.repository.evaluate(
                flagKey,
                context: fh
                    .mapEvaluationContext(_contextMap(context))
                    .strategyContext,
              )
            : connection.repository.evaluate(flagKey);
        resolution = fh.resolveFromEvaluation(
          flagKey,
          kind,
          defaultValue,
          evaluation,
        );
      } on fh.InvalidContextException catch (e) {
        resolution = fh.invalidContextResolution(defaultValue, e);
      } catch (e, s) {
        _log.warning("FeatureHub evaluation of '$flagKey' failed", e, s);
        resolution = fh.generalErrorResolution(defaultValue, e);
      }
    }

    return ResolutionDetails<T>(
      value: resolution.value,
      reason: resolution.reason,
      variant: resolution.variant,
      errorCode: _errorCode(resolution.errorCode),
      errorMessage: resolution.errorMessage,
      flagMetadata: resolution.flagMetadata,
    );
  }

  static ErrorCode? _errorCode(fh.ResolutionErrorCode? code) => switch (code) {
    null => null,
    fh.ResolutionErrorCode.providerNotReady => ErrorCode.providerNotReady,
    fh.ResolutionErrorCode.providerFatal => ErrorCode.providerFatal,
    fh.ResolutionErrorCode.flagNotFound => ErrorCode.flagNotFound,
    fh.ResolutionErrorCode.typeMismatch => ErrorCode.typeMismatch,
    fh.ResolutionErrorCode.parseError => ErrorCode.parseError,
    fh.ResolutionErrorCode.invalidContext => ErrorCode.invalidContext,
    fh.ResolutionErrorCode.general => ErrorCode.general,
  };
}
