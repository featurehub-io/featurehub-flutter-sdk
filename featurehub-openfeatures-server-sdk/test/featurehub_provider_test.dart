import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_server_sdk/featurehub_openfeatures_server_sdk.dart';
import 'package:openfeature_dart_server_sdk/client.dart';
import 'package:openfeature_dart_server_sdk/evaluation_context.dart';
import 'package:openfeature_dart_server_sdk/feature_provider.dart';
import 'package:openfeature_dart_server_sdk/open_feature_api.dart';
import 'package:openfeature_dart_server_sdk/provider_lifecycle.dart';
import 'package:test/test.dart';

/// A transport that delivers [features] (computed from the context header
/// for server-evaluated keys) straight into the repository.
class _FakeTransport implements FeatureHubTransport {
  final ClientFeatureRepository repository;
  List<FeatureState> Function(String? header) features;
  bool fail;
  Duration delay;
  final headers = <String?>[];
  bool closed = false;

  _FakeTransport(
    this.repository,
    this.features, {
    this.fail = false,
    this.delay = Duration.zero,
  });

  Future<void> _deliver() async {
    final header = repository.clientContext.generateHeader();
    headers.add(header);
    await Future<void>.delayed(delay);
    if (fail) {
      repository.notify(SSEResultState.failure, null);
    } else {
      repository.notify(SSEResultState.features, features(header));
    }
  }

  // like a streaming connection, starting does not wait for the features
  @override
  Future<void> start() async => unawaited(_deliver());

  @override
  Future<void> contextChanged() => _deliver();

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async => closed = true;
}

FeatureRolloutStrategyAttribute _attr(String field, List<dynamic> values) =>
    FeatureRolloutStrategyAttribute(
      conditional: RolloutStrategyAttributeConditional.EQUALS,
      fieldName: field,
      values: values,
      type: RolloutStrategyFieldType.STRING,
    );

List<FeatureState> _bundle([String? header]) => [
  FeatureState(
    id: 'f-flag',
    key: 'flag',
    version: 1,
    type: FeatureValueType.BOOLEAN,
    value: true,
  ),
  FeatureState(
    id: 'f-colour',
    key: 'colour',
    version: 2,
    type: FeatureValueType.STRING,
    value: 'blue',
    strategies: [
      FeatureRolloutStrategy(
        id: 'nz-users',
        value: 'green',
        attributes: [
          _attr('country', ['new_zealand']),
        ],
      ),
    ],
  ),
  FeatureState(
    id: 'f-limit',
    key: 'limit',
    version: 1,
    type: FeatureValueType.NUMBER,
    value: 10,
  ),
  FeatureState(
    id: 'f-rate',
    key: 'rate',
    version: 1,
    type: FeatureValueType.NUMBER,
    value: 0.25,
  ),
  FeatureState(
    id: 'f-config',
    key: 'config',
    version: 1,
    type: FeatureValueType.JSON,
    value: '{"retries": 3}',
  ),
  FeatureState(
    id: 'f-empty',
    key: 'empty',
    version: 1,
    type: FeatureValueType.STRING,
  ),
  // server-evaluated: the value is the userkey from the context header
  FeatureState(
    id: 'f-who',
    key: 'who',
    version: 1,
    type: FeatureValueType.STRING,
    value: RegExp(r'userkey=([^,]*)').firstMatch(header ?? '')?[1] ?? 'nobody',
    // the strategy the server applied, if any
    v: header == null ? null : 'by-user',
  ),
];

void main() {
  late OpenFeatureAPI api;
  _FakeTransport? transport;

  FeatureHubProvider provider(
    String apiKey, {
    bool fail = false,
    Duration delay = Duration.zero,
    bool catchAndReleaseMode = false,
    List<FeatureStore> stores = const [],
    List<ValueInterceptor> interceptors = const [],
  }) => FeatureHubProvider(
    environment: const {},
    catchAndReleaseMode: catchAndReleaseMode,
    stores: stores,
    interceptors: interceptors,
    host: 'http://localhost',
    apiKey: apiKey,
    waitForReady: const Duration(seconds: 2),
    connectionFactory: (p) {
      final repository = ClientFeatureRepository();
      transport = _FakeTransport(repository, _bundle, fail: fail, delay: delay);
      return FeatureHubConnection(
        host: p.host,
        apiKey: p.apiKey,
        repository: repository,
        transport: transport,
      );
    },
  );

  setUp(() {
    api = OpenFeatureAPI();
    transport = null;
  });

  tearDown(OpenFeatureAPI.resetInstance);

  test('requires a host and api key', () {
    expect(
      () => FeatureHubProvider(host: '', apiKey: 'x', environment: const {}),
      throwsArgumentError,
    );
  });

  test('without a host and api key, requires stores', () {
    expect(
      () => FeatureHubProvider(environment: const {}),
      throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'host')),
    );
    final p = FeatureHubProvider(
      environment: const {},
      stores: [_RecordingStore([])],
    );
    expect(p.connectsToFeatureHub, false);
    expect(p.host, isNull);
    expect(p.apiKey, isNull);
    expect(p.clientEvaluated, true);
  });

  group('configuration from the environment', () {
    const host = 'http://edge.example.com';

    test('reads the host and client API key', () {
      final p = FeatureHubProvider(
        environment: const {
          'FEATUREHUB_EDGE_URL': host,
          'FEATUREHUB_CLIENT_API_KEY': 'env/key*client',
        },
      );
      expect(p.host, host);
      expect(p.apiKey, 'env/key*client');
      expect(p.clientEvaluated, true);
    });

    test('falls back to the server API key', () {
      final p = FeatureHubProvider(
        environment: const {
          'FEATUREHUB_EDGE_URL': host,
          'FEATUREHUB_SERVER_API_KEY': 'env/key',
        },
      );
      expect(p.apiKey, 'env/key');
      expect(p.clientEvaluated, false);
    });

    test('prefers the client API key over the server one', () {
      final p = FeatureHubProvider(
        environment: const {
          'FEATUREHUB_EDGE_URL': host,
          'FEATUREHUB_SERVER_API_KEY': 'env/key',
          'FEATUREHUB_CLIENT_API_KEY': 'env/key*client',
        },
      );
      expect(p.apiKey, 'env/key*client');
    });

    test('arguments take precedence over the environment', () {
      final p = FeatureHubProvider(
        host: 'http://other',
        apiKey: 'other/key',
        pollInterval: const Duration(seconds: 7),
        environment: const {
          'FEATUREHUB_EDGE_URL': host,
          'FEATUREHUB_CLIENT_API_KEY': 'env/key*client',
          'FEATUREHUB_POLL_INTERVAL': '60',
        },
      );
      expect(p.host, 'http://other');
      expect(p.apiKey, 'other/key');
      expect(p.pollInterval, const Duration(seconds: 7));
    });

    test('streams unless there is a poll interval', () {
      final streaming = FeatureHubProvider(
        environment: const {
          'FEATUREHUB_EDGE_URL': host,
          'FEATUREHUB_CLIENT_API_KEY': 'env/key*client',
        },
      );
      expect(streaming.mode, FeatureHubUpdateMode.streaming);
      expect(streaming.pollInterval, isNull);

      final polling = FeatureHubProvider(
        environment: const {
          'FEATUREHUB_EDGE_URL': host,
          'FEATUREHUB_CLIENT_API_KEY': 'env/key*client',
          'FEATUREHUB_POLL_INTERVAL': '15',
        },
      );
      expect(polling.mode, FeatureHubUpdateMode.activePolling);
      expect(polling.pollInterval, const Duration(seconds: 15));

      final explicit = FeatureHubProvider(
        host: host,
        apiKey: 'env/key*client',
        pollInterval: const Duration(seconds: 5),
        environment: const {},
      );
      expect(explicit.mode, FeatureHubUpdateMode.activePolling);
    });

    test('an explicit mode wins', () {
      final p = FeatureHubProvider(
        mode: FeatureHubUpdateMode.streaming,
        environment: const {
          'FEATUREHUB_EDGE_URL': host,
          'FEATUREHUB_CLIENT_API_KEY': 'env/key*client',
          'FEATUREHUB_POLL_INTERVAL': '15',
        },
      );
      expect(p.mode, FeatureHubUpdateMode.streaming);
      expect(p.pollInterval, isNull);
    });

    test('polling without an interval is an error', () {
      expect(
        () => FeatureHubProvider(
          host: host,
          apiKey: 'env/key*client',
          mode: FeatureHubUpdateMode.activePolling,
          environment: const {},
        ),
        throwsArgumentError,
      );
    });

    test('a missing host or key, or a bad interval, is an error', () {
      expect(
        () => FeatureHubProvider(
          environment: const {'FEATUREHUB_CLIENT_API_KEY': 'env/key*client'},
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'host')),
      );
      expect(
        () => FeatureHubProvider(
          environment: const {'FEATUREHUB_EDGE_URL': host},
        ),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'apiKey')),
      );
      for (final bad in ['soon', '0', '-5']) {
        expect(
          () => FeatureHubProvider(
            environment: {
              'FEATUREHUB_EDGE_URL': host,
              'FEATUREHUB_CLIENT_API_KEY': 'env/key*client',
              'FEATUREHUB_POLL_INTERVAL': bad,
            },
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  group('client-evaluated key', () {
    late FeatureHubProvider p;

    setUp(() async {
      p = provider('env/key*secret');
      await api.setProviderAndWait(p);
    });

    test('resolves every type', () async {
      final client = api.getClient('test');
      expect(await client.getBooleanFlag('flag', defaultValue: false), true);
      expect(await client.getStringFlag('colour', defaultValue: ''), 'blue');
      expect(await client.getIntegerFlag('limit', defaultValue: 0), 10);
      expect(await client.getDoubleFlag('rate', defaultValue: 0), 0.25);
      expect(await client.getObjectFlag('config', defaultValue: {}), {
        'retries': 3,
      });
    });

    test('matching strategies give TARGETING_MATCH with a variant', () async {
      final client = api.getClient('test');
      final details = await client.getStringEvaluationDetails(
        'colour',
        defaultValue: '',
        context: const EvaluationContext(
          targetingKey: 'u1',
          attributes: {'country': 'new_zealand'},
        ),
      );
      expect(details.value, 'green');
      expect(details.reason, 'TARGETING_MATCH');
      expect(details.variant, 'nz-users');
      expect(details.flagMetadata['featureVersion'], 2);

      final other = await client.getStringEvaluationDetails(
        'colour',
        defaultValue: '',
        context: const EvaluationContext(attributes: {'country': 'australia'}),
      );
      expect(other.value, 'blue');
      expect(other.reason, 'STATIC');
    });

    test('never refetches for a new context', () async {
      final client = api.getClient('test');
      for (final country in ['a', 'b', 'c']) {
        await client.getStringFlag(
          'colour',
          defaultValue: '',
          context: EvaluationContext(attributes: {'country': country}),
        );
      }
      expect(transport!.headers, hasLength(1));
    });

    test('errors', () async {
      final client = api.getClient('test');

      final missing = await client.getBooleanEvaluationDetails(
        'missing',
        defaultValue: true,
      );
      expect(missing.value, true);
      expect(missing.errorCode, ErrorCode.FLAG_NOT_FOUND);

      final mismatch = await client.getBooleanEvaluationDetails(
        'colour',
        defaultValue: false,
      );
      expect(mismatch.errorCode, ErrorCode.TYPE_MISMATCH);

      final empty = await client.getStringEvaluationDetails(
        'empty',
        defaultValue: 'd',
      );
      expect(empty.value, 'd');
      expect(empty.reason, 'DISABLED');
      expect(empty.errorCode, isNull);

      final invalid = await client.getStringEvaluationDetails(
        'colour',
        defaultValue: 'd',
        context: const EvaluationContext(
          attributes: {
            'nested': {'a': 1},
          },
        ),
      );
      expect(invalid.errorCode, ErrorCode.INVALID_CONTEXT);
    });

    test('announces changed flags', () async {
      final events = <ProviderLifecycleEvent>[];
      final sub = p.providerEvents.listen(events.add);

      p.repository!.notify(SSEResultState.feature, {
        'id': 'f-flag',
        'key': 'flag',
        'version': 2,
        'type': 'BOOLEAN',
        'value': false,
        'l': false,
      });
      await Future<void>.delayed(Duration.zero);

      expect(
        events.single.type,
        ProviderLifecycleEventType.PROVIDER_CONFIGURATION_CHANGED,
      );
      expect(events.single.flagsChanged, ['flag']);
      expect(
        await api.getClient('test').getBooleanFlag('flag', defaultValue: true),
        false,
      );
      await sub.cancel();
    });

    test('a lost connection is not stale', () async {
      final events = <ProviderLifecycleEventType>[];
      final sub = p.providerEvents.listen((e) => events.add(e.type));

      p.repository!.notify(SSEResultState.bye, null);
      p.repository!.notify(SSEResultState.features, _bundle());
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });

    test('a rejection after features is stale, and keeps resolving', () async {
      final events = <ProviderLifecycleEvent>[];
      final sub = p.providerEvents.listen(events.add);

      p.repository!.notify(SSEResultState.failure, null);
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.type), [
        ProviderLifecycleEventType.PROVIDER_STALE,
      ]);
      expect(events.single.message, contains('will not be updated again'));
      final client = api.getClient('test');
      expect(await client.getBooleanFlag('flag', defaultValue: false), true);
      await sub.cancel();
    });

    test('shutdown closes the connection', () async {
      await api.dispose();
      expect(transport!.closed, true);
    });
  });

  test('catch and release can be switched on at creation', () async {
    final p = provider('env/key*secret', catchAndReleaseMode: true);
    final events = <ProviderLifecycleEvent>[];
    p.providerEvents.listen(events.add);

    await api.setProviderAndWait(p);
    expect(p.catchAndReleaseMode, true);
    expect(p.repository!.catchAndReleaseMode, true);
    final client = api.getClient('test');
    expect(await client.getBooleanFlag('flag', defaultValue: false), true);

    // an update is held back...
    p.repository!.notify(SSEResultState.feature, {
      'id': 'f-flag',
      'key': 'flag',
      'version': 2,
      'type': 'BOOLEAN',
      'value': false,
      'l': false,
    });
    await Future<void>.delayed(Duration.zero);
    expect(await client.getBooleanFlag('flag', defaultValue: true), true);
    expect(events.map((e) => e.type), [
      ProviderLifecycleEventType.PROVIDER_READY,
    ]);

    // ...until it is released
    await p.release();
    await Future<void>.delayed(Duration.zero);
    expect(await client.getBooleanFlag('flag', defaultValue: true), false);
    expect(
      events.last.type,
      ProviderLifecycleEventType.PROVIDER_CONFIGURATION_CHANGED,
    );
    expect(events.last.flagsChanged, ['flag']);
  });

  test('stores are attached before connecting, and closed', () async {
    final store = _RecordingStore([
      FeatureState(
        id: 'f-flag',
        key: 'flag',
        version: 1,
        type: FeatureValueType.BOOLEAN,
        value: false,
      ),
    ]);
    final p = provider(
      'default/env-1/key*secret',
      delay: const Duration(milliseconds: 200),
      stores: [store],
    );

    // ready from the store's features, before FeatureHub has answered
    await api.setProviderAndWait(p);
    expect(transport!.headers, hasLength(1));
    expect(
      await api.getClient('test').getBooleanFlag('flag', defaultValue: true),
      false,
    );

    // FeatureHub's features then arrive, and the store sees them
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      await api.getClient('test').getBooleanFlag('flag', defaultValue: false),
      true,
    );
    expect(store.updates.single, isA<FeaturesReceived>());
    expect(store.updates.single.source, featureHubEdgeSource);

    await OpenFeatureAPI.resetInstance();
    expect(store.events, ['attach env-1', 'close']);
  });

  test('interceptors override values, and are closed', () async {
    final interceptor = _FlagOff();
    final p = provider('default/env-1/key*secret', interceptors: [interceptor]);
    await api.setProviderAndWait(p);
    await Future<void>.delayed(Duration.zero);

    // FeatureHub has flag on; the interceptor turns it off
    expect(
      await api.getClient('test').getBooleanFlag('flag', defaultValue: true),
      false,
    );
    expect(p.repository!.evaluate('flag').intercepted, true);

    await OpenFeatureAPI.resetInstance();
    expect(interceptor.closed, true);
  });

  group('server-evaluated key', () {
    test('refetches only when the context changes', () async {
      await api.setProviderAndWait(provider('env/key'));
      final client = api.getClient('test');

      Future<String> who(String user) => client.getStringFlag(
        'who',
        defaultValue: '',
        context: EvaluationContext(targetingKey: user, attributes: const {}),
      );

      expect(await who('fred'), 'fred');
      expect(await who('fred'), 'fred');
      expect(await who('mary'), 'mary');

      // the strategy the server applied is reported as the variant
      final details = await client.getStringEvaluationDetails(
        'who',
        defaultValue: '',
        context: EvaluationContext(targetingKey: 'mary', attributes: const {}),
      );
      expect(details.reason, 'TARGETING_MATCH');
      expect(details.variant, 'by-user');
      // the initial (empty) context, fred, then mary
      expect(transport!.headers, [null, 'userkey=fred', 'userkey=mary']);
    });

    test('concurrent resolutions never see another context', () async {
      await api.setProviderAndWait(
        provider('env/key', delay: const Duration(milliseconds: 5)),
      );
      final client = api.getClient('test');

      final users = List.generate(10, (i) => 'user$i');
      final results = await Future.wait([
        for (final u in [...users, ...users.reversed])
          client.getStringFlag(
            'who',
            defaultValue: '',
            context: EvaluationContext(targetingKey: u, attributes: const {}),
          ),
      ]);
      expect(results, [...users, ...users.reversed]);
    });
  });

  test('a rejected key fails initialization, closing the stores', () async {
    final store = _RecordingStore([]);
    final p = provider('env/key*secret', fail: true, stores: [store]);
    final events = <ProviderLifecycleEvent>[];
    p.providerEvents.listen(events.add);

    await expectLater(
      api.setProviderAndWait(p),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.code,
          'code',
          ErrorCode.PROVIDER_FATAL,
        ),
      ),
    );
    expect(events.single.type, ProviderLifecycleEventType.PROVIDER_ERROR);
    expect(store.events, ['attach env', 'close']);
  });

  test('an invalid initial context starts nothing', () async {
    final store = _RecordingStore([]);
    final p = provider('env/key', stores: [store]);
    await expectLater(
      p.initializeProvider(
        const EvaluationContext(
          attributes: {
            'nested': {'a': 1},
          },
        ),
      ),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.code,
          'code',
          ErrorCode.INVALID_CONTEXT,
        ),
      ),
    );
    expect(store.events, isEmpty);
    expect(p.repository, isNull);
    expect(transport, isNull);
  });

  test('resolutions before initialization are not ready', () async {
    final p = provider('env/key*secret');
    final result = await p.getBooleanFlag('flag', false);
    expect(result.value, false);
    expect(result.errorCode, ErrorCode.PROVIDER_NOT_READY);
  });

  group('against a FeatureHub Edge', () {
    late HttpServer edge;
    var hang = 0;

    setUp(() async {
      hang = 0;
      edge = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      edge.listen((request) async {
        if (hang > 0) {
          hang--;
          return; // never respond
        }
        final features = jsonEncode(_bundle().map((f) => f.toJson()).toList());
        final response = request.response;
        if (request.uri.path == '/features') {
          response.headers.contentType = ContentType.json;
          response.write('[{"id": "env", "features": $features}]');
          await response.close();
        } else {
          response.headers.contentType = ContentType('text', 'event-stream');
          response.bufferOutput = false;
          response.write('event: features\ndata: $features\n\n');
          await response.flush();
        }
      });
    });

    tearDown(() => edge.close(force: true));

    test(
      'an unanswered connection is retried after the request timeout',
      () async {
        hang = 1;
        await api.setProviderAndWait(
          FeatureHubProvider(
            environment: const {},
            host: 'http://127.0.0.1:${edge.port}',
            apiKey: 'env/key*secret',
            requestTimeout: const Duration(milliseconds: 200),
            connectTimeout: const Duration(seconds: 2),
            reconnectPolicy: const ReconnectPolicy(
              delay: Duration(milliseconds: 10),
            ),
          ),
        );
        expect(
          await api
              .getClient('test')
              .getBooleanFlag('flag', defaultValue: false),
          true,
        );
      },
    );

    for (final mode in FeatureHubUpdateMode.values) {
      test('resolves flags (${mode.name})', () async {
        await api.setProviderAndWait(
          FeatureHubProvider(
            environment: const {},
            host: 'http://127.0.0.1:${edge.port}',
            apiKey: 'env/key*secret',
            mode: mode,
            pollInterval: const Duration(seconds: 30),
          ),
        );
        final details = await api
            .getClient('test')
            .getStringEvaluationDetails(
              'colour',
              defaultValue: '',
              context: const EvaluationContext(
                attributes: {'country': 'new_zealand'},
              ),
            );
        expect(details.value, 'green');
        expect(details.variant, 'nz-users');
      });
    }
  });
}

/// A store that holds [stored] and records what it sees.
class _RecordingStore implements FeatureStore {
  final List<FeatureState> stored;
  final events = <String>[];
  final updates = <RawFeatureUpdate>[];
  StreamSubscription<RawFeatureUpdate>? _sub;

  _RecordingStore(this.stored);

  @override
  bool get connected => _sub != null;

  @override
  Future<void> attach(FeatureStoreTarget target) async {
    events.add('attach ${target.environmentId}');
    _sub = target.repository.rawFeatureUpdates.listen((u) {
      if (u.source != 'test-store') updates.add(u);
    });
    if (stored.isEmpty) return;
    target.repository.notify(
      SSEResultState.features,
      stored,
      source: 'test-store',
    );
  }

  @override
  Future<void> close() async {
    events.add('close');
    await _sub?.cancel();
    _sub = null;
  }
}

/// Turns `flag` off, and records being closed.
class _FlagOff extends ValueInterceptor {
  var closed = false;

  @override
  ValueMatch matched(String key, FeatureState? featureState) =>
      key == 'flag' ? const ValueMatch(true, false) : ValueMatch.none;

  @override
  void close() => closed = true;
}
