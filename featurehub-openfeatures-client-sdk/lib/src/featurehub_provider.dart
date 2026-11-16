import 'dart:async';

import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    as fh;
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
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
/// The OpenFeature `targetingKey` is FeatureHub's `userkey`; see
/// [fh.mapEvaluationContext] for how other attributes are mapped.
final class FeatureHubProvider
    implements
        FeatureProvider,
        InitializableProvider,
        ShutdownProvider,
        ContextReconciliationProvider,
        ProviderEventSource {
  /// The FeatureHub Edge URL, e.g. `https://edge.example.com`.
  final String host;

  /// The environment's SDK API key.
  final String apiKey;

  final fh.FeatureHubUpdateMode mode;

  /// For [fh.FeatureHubUpdateMode.polling], how often to poll; for
  /// [fh.FeatureHubUpdateMode.passive], how old the features may get before a
  /// resolution refreshes them (in the background).
  final Duration pollInterval;

  /// How long initialization and a context change wait for features.
  final Duration waitForReady;

  final ReconnectPolicy reconnectPolicy;

  /// How long establishing an HTTP connection may take (null: indefinitely).
  /// In browsers this applies only to polling, since the browser controls
  /// `EventSource` connections.
  final Duration? connectTimeout;

  /// How long a polling request may take, or how long a streaming connection
  /// attempt waits for the stream to open (null: indefinitely). A streaming
  /// attempt that times out is retried according to [reconnectPolicy].
  final Duration? requestTimeout;

  /// True if [apiKey] is client-evaluated.
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

  /// [connectionFactory] replaces the connection to FeatureHub (for tests).
  FeatureHubProvider({
    required this.host,
    required this.apiKey,
    this.mode = fh.FeatureHubUpdateMode.streaming,
    this.pollInterval = const Duration(seconds: 30),
    this.waitForReady = const Duration(seconds: 10),
    this.reconnectPolicy = const ReconnectPolicy(),
    this.connectTimeout,
    this.requestTimeout,
    this._catchAndReleaseMode = false,
    this.stores = const [],
    this.interceptors = const [],
    this._connectionFactory,
  }) : clientEvaluated = fh.FeatureHubConfig.isClientEvaluatedKeys([apiKey]) {
    if (host.isEmpty || apiKey.isEmpty) {
      throw ArgumentError('FeatureHubProvider requires a host and an apiKey');
    }
  }

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
    final connection =
        _connectionFactory?.call(this) ??
        fh.FeatureHubConnection(
          host: host,
          apiKey: apiKey,
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
          ),
        );
      } catch (e, s) {
        _log.warning('A FeatureHub store failed to attach', e, s);
      }
    }

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

    await connection.start(context: initialContext);
    final readiness = await connection.waitForReady(waitForReady);

    if (readiness != fh.Readyness.Ready) {
      final fatal = readiness == fh.Readyness.Failed;
      _emit(
        ProviderEventType.error,
        message: fatal
            ? 'FeatureHub rejected the API key, or the environment does not exist.'
            : 'FeatureHub did not become ready within $waitForReady.',
        errorCode: fatal ? ErrorCode.providerFatal : ErrorCode.general,
      );
      await connection.close();
      _connection = null;
      return;
    }

    _ready = true;
    _tracker = fh.ProviderStateTracker(
      connection.repository,
      onStale: () => _emit(
        ProviderEventType.stale,
        message:
            'Lost the connection to FeatureHub; features may be out of date',
      ),
      onRecovered: () => _emit(ProviderEventType.ready),
      onFatal: () {
        _ready = false;
        _emit(
          ProviderEventType.error,
          message:
              'FeatureHub rejected the API key, or the environment no longer exists',
          errorCode: ErrorCode.providerFatal,
        );
      },
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
    if (clientEvaluated || connection == null) {
      // client-evaluated features are evaluated against each new context
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
    final readiness = await connection.setContext(mapped, waitForReady);
    if (readiness == fh.Readyness.Failed) {
      _emit(
        ProviderEventType.error,
        message: 'FeatureHub failed to fetch the features for the new context',
        errorCode: ErrorCode.providerFatal,
      );
    } else {
      _emit(ProviderEventType.contextChanged);
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
    for (final store in stores) {
      await store.close();
    }
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
        if (mode == fh.FeatureHubUpdateMode.passive) {
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
