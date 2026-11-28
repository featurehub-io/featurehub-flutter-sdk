// conformance: polling-zero-interval, polling-negative-interval,
// polling-minimum-interval, polling-max-age-only-on-success
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_common/src/transport/polling_limits.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi_dart_common/openapi.dart';
import 'package:test/test.dart';

/// Answers FeatureHub polling (`/features?apiKey=`) and a features snapshot
/// (`/snapshot`), counting the requests.
class _Server {
  late HttpServer _server;
  final requests = <HttpRequest>[];
  String? cacheControl;

  String get host => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      requests.add(request);
      final feature = {
        'id': 'fv-pastry',
        'key': 'kwong_pastry',
        'version': 1,
        'type': 'STRING',
        'value': 'egg tart',
      };
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (cacheControl != null) {
        response.headers.set(HttpHeaders.cacheControlHeader, cacheControl!);
      }
      response.write(
        jsonEncode(
          request.uri.path == '/snapshot'
              ? {
                  'features': [feature],
                }
              : [
                  {
                    'id': 'env',
                    'features': [feature],
                  },
                ],
        ),
      );
      await response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

class _Repository extends Mock implements ClientFeatureRepository {
  @override
  final ClientContext clientContext = ClientContext();
}

void main() {
  late _Server server;

  setUp(() async {
    server = _Server();
    await server.start();
  });
  tearDown(() => server.stop());

  FeatureHubConnection connect(
    FeatureHubUpdateMode mode,
    Duration interval, {
    bool snapshot = false,
  }) => snapshot
      ? FeatureHubConnection(
          featuresUrl: '${server.host}/snapshot',
          mode: mode,
          pollInterval: interval,
        )
      : FeatureHubConnection(
          host: server.host,
          apiKey: 'lingling/kwong*pastry',
          mode: mode,
          pollInterval: interval,
        );

  group('an interval of zero polls once', () {
    for (final snapshot in [false, true]) {
      for (final mode in [
        FeatureHubUpdateMode.activePolling,
        FeatureHubUpdateMode.passivePolling,
      ]) {
        test('${snapshot ? 'snapshot' : 'FeatureHub'}, ${mode.name}', () async {
          // a max-age does not start polling again
          server.cacheControl = 'max-age=1';
          minPollingInterval = const Duration(milliseconds: 1);
          addTearDown(() => minPollingInterval = defaultMinPollingInterval);

          final c = connect(mode, Duration.zero, snapshot: snapshot);
          await c.start();
          expect(c.repository.readyness, Readyness.Ready);
          for (var i = 0; i < 5; i++) {
            await c.refreshIfStale();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          await c.refreshIfStale();

          expect(server.requests, hasLength(1));
          // neither stopped nor failed
          expect(c.repository.readyness, Readyness.Ready);
          expect(c.repository.environmentStale, false);
          expect(c.repository.evaluate('kwong_pastry').value, 'egg tart');
          await c.close();
        });
      }
    }

    test('a context change still makes its request', () async {
      final c = FeatureHubConnection(
        host: server.host,
        apiKey: 'lingling/kwong', // server-evaluated: sends the context
        mode: FeatureHubUpdateMode.activePolling,
        pollInterval: Duration.zero,
      );
      await c.start();
      await c.setContext(
        mapEvaluationContext({'targetingKey': 'orm'}),
        const Duration(seconds: 5),
      );
      expect(server.requests, hasLength(2));
      await c.close();
    });
  });

  group('validation', () {
    for (final snapshot in [false, true]) {
      final source = snapshot ? 'snapshot' : 'FeatureHub';
      for (final mode in [
        FeatureHubUpdateMode.activePolling,
        FeatureHubUpdateMode.passivePolling,
      ]) {
        test('$source, ${mode.name}', () {
          for (final bad in [
            const Duration(seconds: -1),
            const Duration(seconds: 4),
            const Duration(milliseconds: 1),
          ]) {
            expect(
              () => connect(mode, bad, snapshot: snapshot),
              throwsA(
                isA<ArgumentError>().having(
                  (e) => e.name,
                  'name',
                  'pollInterval',
                ),
              ),
              reason: '$bad',
            );
          }
          for (final good in [Duration.zero, const Duration(seconds: 5)]) {
            connect(mode, good, snapshot: snapshot);
          }
        });
      }
    }

    test('streaming ignores the poll interval', () {
      FeatureHubConnection(
        host: server.host,
        apiKey: 'lingling/kwong*pastry',
        pollInterval: const Duration(seconds: 1),
      );
    });
  });

  // conformance: polling-poll-interval, polling-poll-interval-only-on-success,
  // polling-minimum-interval (featurehub_edge.polling.poll_interval.examples)
  group('pollInterval', () {
    late FeatureHubRestClient client;

    setUp(() {
      client = FeatureHubRestClient(
        server.host,
        ['lingling/kwong*pastry'],
        _Repository(),
        interval: const Duration(seconds: 60),
      );
    });

    Future<void> respond(int status, List<int?> intervals) =>
        client.decodeResponse(
          ApiResponse(
            status,
            {
              'cache-control': ['max-age=7'],
            },
            Stream.value(
              utf8.encode(
                jsonEncode([
                  for (final (i, seconds) in intervals.indexed)
                    {'id': 'env-$i', 'features': [], 'pollInterval': seconds},
                ]),
              ),
            ),
          ),
        );

    for (final (intervals, expected) in [
      ([30], 30),
      ([120], 120),
      ([45, 20, null], 20),
      ([3, 40], 40),
      ([5], 5),
      ([4, 5], 5),
      (<int?>[1], 60),
      (<int?>[], 60),
    ]) {
      test('$intervals gives ${expected}s', () async {
        await respond(200, intervals);
        expect(client.timeoutInSeconds, expected);
      });
    }

    test(
      'a full response without one returns to the configured interval',
      () async {
        await respond(200, [30]);
        expect(client.serverPollInterval, const Duration(seconds: 30));
        await respond(200, []);
        expect(client.serverPollInterval, isNull);
        expect(client.timeoutInSeconds, 60);
      },
    );

    test(
      'only a 200 or 236 body changes it; Cache-Control never does',
      () async {
        for (final status in [304, 429, 502, 503]) {
          await client.decodeResponse(
            ApiResponse(status, {
              'cache-control': ['max-age=7'],
            }, null),
          );
          expect(client.serverPollInterval, isNull, reason: '$status');
        }
        await respond(236, [12]);
        expect(client.serverPollInterval, const Duration(seconds: 12));
      },
    );
  });
}
