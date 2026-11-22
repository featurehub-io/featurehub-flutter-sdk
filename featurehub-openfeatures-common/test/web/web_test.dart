@TestOn('browser')
library;

import 'dart:async';

import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:async/async.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

/// murmur3 values from the TypeScript SDK (see
/// test/strategy/fixtures/typescript_golden.json): checks the 32-bit
/// arithmetic is exact when compiled to JavaScript.
const _murmur = {
  '': 0,
  'a': 1009084850,
  'ab': 2613040991,
  'abc': 3017643002,
  'abcd': 1139631978,
  'abcde': 3902511862,
  'abcdefg': 2285673222,
  'abcdefgh': 1239272644,
  'abcdefghi': 1108608752,
  'irina': 2204407971,
  'irinaone': 4026795837,
  r'fred$NZ': 196420430,
  '日本語': 2779017879,
  'émoji 😀': 132264109,
  'user-12345feature-abcdef': 3493944681,
};

const _percentages = {
  'user0': 15345,
  'user1': 178815,
  'user2': 278206,
  'user3': 746318,
  'user4': 560200,
  'user5': 769723,
  'user6': 952670,
  'user7': 856980,
  'user8': 444435,
  'user9': 442587,
};

void main() {
  test('murmur3 matches TypeScript in the browser', () {
    _murmur.forEach((key, hash) => expect(murmur3String(key), hash));
    const calc = Murmur3PercentageCalculator();
    _percentages.forEach(
      (key, value) => expect(calc.determineClientPercentage(key, 'fv1'), value),
    );
  });

  group('web polling', () {
    late StreamChannel<Object?> server;
    late StreamQueue<Object?> messages;

    setUp(() async {
      server = spawnHybridUri('sse_server.dart');
      messages = StreamQueue(server.stream);
    });

    tearDown(() => server.sink.close());

    test('accepts gzip-compressed responses', () async {
      final host = 'http://127.0.0.1:${await messages.next}';
      final repo = ClientFeatureRepository();
      await FeatureHubRestClient(host, ['a/b/c'], repo).request();

      // the browser negotiates (and decompresses) the encoding itself
      Map request;
      do {
        request = await messages.next as Map; // skip the generic request report
      } while (!request.containsKey('acceptEncoding'));
      expect(request['acceptEncoding'], contains('gzip'));
      expect(repo.readyness, Readyness.Ready);
      expect(repo.getString('colour'), 'blue');
    });
  });

  group('web SSE listener', () {
    late StreamChannel<Object?> server;
    late StreamQueue<Object?> messages;
    late String host;

    setUp(() async {
      server = spawnHybridUri('sse_server.dart');
      messages = StreamQueue(server.stream);
      host = 'http://127.0.0.1:${await messages.next}';
    });

    tearDown(() => server.sink.close());

    Future<void> until(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('receives features', () async {
      final repo = ClientFeatureRepository();
      final listener = EventSourceRepositoryListener(host, 'a/b/c', repo);

      await until(() => repo.readyness == Readyness.Ready);
      expect(repo.getString('colour'), 'blue');
      expect(listener.closed, false);
      listener.close();
    });

    test('sends the context as a query parameter', () async {
      final repo = ClientFeatureRepository();
      repo.clientContext.userKey('fred');
      final listener = EventSourceRepositoryListener(host, 'a/b/c', repo);

      final request = await messages.next as Map;
      expect(request['path'], '/features/a/b/c');
      expect(request['xfeaturehub'], 'userkey=fred');

      // a context change reconnects with the new context
      repo.clientContext.userKey('mary').build();
      final next = await messages.next as Map;
      expect(next['xfeaturehub'], 'userkey=mary');
      listener.close();
    });

    // conformance: query-parameter-order, sdk-version
    test('sends contextSha, sdk_version, then xfeaturehub', () async {
      final repo = ClientFeatureRepository();
      repo.clientContext.userKey('ling');
      final listener = EventSourceRepositoryListener(host, 'a/b/c', repo);

      final request = await messages.next as Map;
      final names = (request['query'] as String)
          .split('&')
          .map((p) => p.split('=').first)
          .toList();
      expect(names, ['contextSha', 'sdk_version', 'xfeaturehub']);
      expect(request['query'], contains('sdk_version=2'));
      expect(request['query'], isNot(contains('contextSha=0')));
      listener.close();
    });

    // conformance: streaming-short-connections
    test('a short connection is a failure: it backs off, and gives up at the '
        'maximum attempts', () async {
      final repo = ClientFeatureRepository();
      final listener = EventSourceRepositoryListener(
        host,
        'a/b/short*c',
        repo,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 10),
          maxAttempts: 2,
        ),
      );

      await until(() => listener.closed);
      // the features came first: the connection failed, readiness is Stale
      expect(repo.connectionFailed, true);
      expect(repo.readyness, Readyness.Stale);
      expect(repo.getString('colour'), 'blue');
      final requests = <Map>[];
      while (await messages.hasNext.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => false,
      )) {
        requests.add(await messages.next as Map);
      }
      // the first connection and 2 attempts, each a new EventSource that the
      // listener opened (so without a Last-Event-ID)
      expect(requests, hasLength(3));
      expect(requests.map((r) => r['lastEventId']).toSet(), {null});
      expect(requests.first['query'], 'contextSha=0&sdk_version=2');
    });

    test('never sends the context for client-evaluated keys', () async {
      final repo = ClientFeatureRepository();
      repo.clientContext.userKey('fred');
      final listener = EventSourceRepositoryListener(host, 'a/b/c*d', repo);
      expect(listener.clientEvaluated, true);

      final request = await messages.next as Map;
      expect(request['xfeaturehub'], isNull);
      listener.close();
    });

    test('an attempt that does not open in time is retried', () async {
      final repo = ClientFeatureRepository();
      final listener = EventSourceRepositoryListener(
        host,
        'a/b/slow',
        repo,
        requestTimeout: const Duration(milliseconds: 300),
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 10),
        ),
      );

      expect((await messages.next as Map)['hung'], true);
      await until(() => repo.readyness == Readyness.Ready);
      expect(repo.getString('colour'), 'blue');
      listener.close();
    });

    for (final key in ['a/b/gone', 'a/b/broken']) {
      test(
        'a connection error ($key) is final: the stream stops, failed',
        () async {
          final repo = ClientFeatureRepository();
          final listener = EventSourceRepositoryListener(
            host,
            key,
            repo,
            reconnectPolicy: const ReconnectPolicy(
              delay: Duration(milliseconds: 10),
              serverErrorDelay: Duration(milliseconds: 10),
            ),
          );

          await until(() => listener.closed);
          expect(repo.readyness, Readyness.Failed);
          // no reconnection: one request only
          expect((await messages.next as Map)['path'], '/features/$key');
          final another = await messages.hasNext.timeout(
            const Duration(milliseconds: 500),
            onTimeout: () => false,
          );
          expect(another, false, reason: 'no reconnection');
        },
      );
    }

    test('a failure event closes the connection', () async {
      final repo = ClientFeatureRepository();
      final listener = EventSourceRepositoryListener(host, 'a/b/fail', repo);

      await until(() => listener.closed);
      // the features came first: the connection failed, readiness is Stale
      expect(repo.connectionFailed, true);
      expect(repo.readyness, Readyness.Stale);
    });
  });
}
