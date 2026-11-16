import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_client_sdk/featurehub_openfeatures_client_sdk.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    as fh;
import 'package:openfeature_dart_client_sdk/openfeature_dart_client_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final api = OpenFeatureAPI.instance;
  FakeTransport? transport;

  FeatureHubProvider provider(
    String apiKey, {
    bool fail = false,
    bool catchAndReleaseMode = false,
    List<fh.FeatureStore> stores = const [],
  }) => FeatureHubProvider(
    catchAndReleaseMode: catchAndReleaseMode,
    stores: stores,
    host: 'http://localhost',
    apiKey: apiKey,
    waitForReady: const Duration(seconds: 2),
    connectionFactory: (p) {
      final repository = fh.ClientFeatureRepository();
      transport = FakeTransport(repository, bundle, fail: fail);
      return fh.FeatureHubConnection(
        host: p.host,
        apiKey: p.apiKey,
        repository: repository,
        transport: transport,
      );
    },
  );

  setUp(() => transport = null);
  tearDown(api.shutdown);

  test('requires a host and api key', () {
    expect(
      () => FeatureHubProvider(host: 'http://x', apiKey: ''),
      throwsArgumentError,
    );
  });

  group('client-evaluated key', () {
    late FeatureHubProvider p;

    setUp(() async {
      p = provider('env/key*secret');
      await api.setProviderAndWait(p);
    });

    test('resolves every type synchronously', () {
      final client = api.getClient();
      expect(client.getBooleanValue('flag', false), true);
      expect(client.getStringValue('colour', ''), 'blue');
      expect(client.getIntegerValue('limit', 0), 10);
      expect(client.getDoubleValue('rate', 0), 0.25);
      expect(client.getStructureValue('config', const {}), {'retries': 3});
    });

    test('evaluates strategies against the current context', () async {
      final client = api.getClient();
      await api.setEvaluationContextAndWait(
        EvaluationContext(
          targetingKey: 'u1',
          attributes: {'country': 'new_zealand'},
        ),
      );
      final details = client.getStringDetails('colour', '');
      expect(details.value, 'green');
      expect(details.reason, 'TARGETING_MATCH');
      expect(details.variant, 'nz-users');
      expect(details.flagMetadata['featureVersion'], 2);

      await api.setEvaluationContextAndWait(
        EvaluationContext(attributes: {'country': 'australia'}),
      );
      expect(client.getStringDetails('colour', '').reason, 'STATIC');
      expect(transport!.headers, hasLength(1), reason: 'no refetch');
    });

    test('errors', () {
      final client = api.getClient();
      expect(
        client.getBooleanDetails('missing', true).errorCode,
        ErrorCode.flagNotFound,
      );
      expect(
        client.getBooleanDetails('colour', false).errorCode,
        ErrorCode.typeMismatch,
      );
      expect(
        client.getIntegerDetails('rate', 0).errorCode,
        ErrorCode.typeMismatch,
      );
      final empty = client.getStringDetails('empty', 'd');
      expect(empty.value, 'd');
      expect(empty.reason, 'DEFAULT');
    });

    test('announces changed flags', () async {
      final events = <ProviderEvent>[];
      final sub = p.events.listen(events.add);

      p.repository!.notify(SSEResultState.feature, {
        'id': 'f-flag',
        'key': 'flag',
        'version': 2,
        'type': 'BOOLEAN',
        'value': false,
        'l': false,
      });
      await Future<void>.delayed(Duration.zero);

      expect(events.single.type, ProviderEventType.configurationChanged);
      expect(events.single.flagsChanged, ['flag']);
      expect(api.getClient().getBooleanValue('flag', true), false);
      await sub.cancel();
    });

    test('goes stale and recovers', () async {
      final events = <ProviderEventType>[];
      final sub = p.events.listen((e) => events.add(e.type));

      p.repository!.notify(SSEResultState.bye, null);
      p.repository!.notify(SSEResultState.features, bundle());
      await Future<void>.delayed(Duration.zero);

      expect(events, [ProviderEventType.stale, ProviderEventType.ready]);
      await sub.cancel();
    });

    test('shutdown closes the connection', () async {
      await api.shutdown();
      expect(transport!.closed, true);
    });
  });

  test('catch and release can be switched on at creation', () async {
    final p = provider('env/key*secret', catchAndReleaseMode: true);
    final events = <ProviderEvent>[];
    p.events.listen(events.add);

    await api.setProviderAndWait(p);
    final client = api.getClient();
    expect(client.getBooleanValue('flag', false), true);

    p.repository!.notify(SSEResultState.feature, {
      'id': 'f-flag',
      'key': 'flag',
      'version': 2,
      'type': 'BOOLEAN',
      'value': false,
      'l': false,
    });
    await Future<void>.delayed(Duration.zero);
    expect(client.getBooleanValue('flag', true), true, reason: 'held back');
    expect(events.map((e) => e.type), [ProviderEventType.ready]);

    await p.release();
    await Future<void>.delayed(Duration.zero);
    expect(client.getBooleanValue('flag', true), false);
    expect(events.last.type, ProviderEventType.configurationChanged);
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
    final p = provider('default/env-1/key*secret', stores: [store]);
    await api.setProviderAndWait(p);
    await Future<void>.delayed(Duration.zero);

    // FeatureHub's features replace the stored ones, and the store sees them
    expect(api.getClient().getBooleanValue('flag', false), true);
    expect(store.updates.single, isA<fh.FeaturesReceived>());
    expect(store.updates.single.source, fh.featureHubEdgeSource);

    await api.shutdown();
    expect(store.events, ['attach env-1', 'close']);
  });

  group('server-evaluated key', () {
    test('fetches the bundle for each new context', () async {
      await api.setEvaluationContextAndWait(
        EvaluationContext(targetingKey: 'fred'),
      );
      final p = provider('env/key');
      await api.setProviderAndWait(p);
      final client = api.getClient();
      expect(client.getStringValue('who', ''), 'fred');

      final events = <ProviderEventType>[];
      final sub = p.events.listen((e) => events.add(e.type));
      await api.setEvaluationContextAndWait(
        EvaluationContext(targetingKey: 'mary'),
      );
      expect(client.getStringValue('who', ''), 'mary');

      // the strategy the server applied is reported as the variant
      final details = client.getStringDetails('who', '');
      expect(details.reason, 'TARGETING_MATCH');
      expect(details.variant, 'by-user');
      expect(events, [
        ProviderEventType.reconciling,
        ProviderEventType.contextChanged,
      ]);
      expect(transport!.headers, ['userkey=fred', 'userkey=mary']);
      await sub.cancel();
    });

    test('an invalid context is an error', () async {
      final p = provider('env/key');
      await api.setProviderAndWait(p);
      final events = <ProviderEvent>[];
      final sub = p.events.listen(events.add);

      await expectLater(
        api.setEvaluationContextAndWait(
          EvaluationContext(
            attributes: {
              'nested': {'a': 1},
            },
          ),
        ),
        throwsA(isA<OpenFeatureException>()),
      );
      expect(events.last.errorCode, ErrorCode.invalidContext);
      await sub.cancel();
    });
  });

  test('a rejected key fails initialization', () async {
    final p = provider('env/key*secret', fail: true);
    await expectLater(
      api.setProviderAndWait(p),
      throwsA(
        isA<OpenFeatureException>().having(
          (e) => e.errorCode,
          'errorCode',
          ErrorCode.providerFatal,
        ),
      ),
    );
  });

  test('resolutions before initialization are not ready', () {
    final p = provider('env/key*secret');
    final result = p.resolveBooleanValue(
      'flag',
      false,
      EvaluationContext.empty,
    );
    expect(result.value, false);
    expect(result.errorCode, ErrorCode.providerNotReady);
  });
}

/// A store that holds [stored] and records what it sees.
class _RecordingStore implements fh.FeatureStore {
  final List<FeatureState> stored;
  final events = <String>[];
  final updates = <fh.RawFeatureUpdate>[];
  StreamSubscription<fh.RawFeatureUpdate>? _sub;

  _RecordingStore(this.stored);

  @override
  bool get connected => _sub != null;

  @override
  Future<void> attach(fh.FeatureStoreTarget target) async {
    events.add('attach ${target.environmentId}');
    _sub = target.repository.rawFeatureUpdates.listen((u) {
      if (u.source != 'test-store') updates.add(u);
    });
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
