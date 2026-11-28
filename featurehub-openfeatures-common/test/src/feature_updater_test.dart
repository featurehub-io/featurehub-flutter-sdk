// conformance: feature-update-request, feature-update-outcomes
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

class _Request {
  final String method;
  final String path;
  final String query;
  final Map<String, String> headers;
  final Object? body;

  _Request(this.method, this.path, this.query, this.headers, this.body);
}

void main() {
  late HttpServer server;
  late String host;
  final requests = <_Request>[];
  var status = 200;
  String? retryAfter;

  setUp(() async {
    requests.clear();
    status = 200;
    retryAfter = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    host = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final text = await utf8.decodeStream(request);
      final headers = <String, String>{};
      request.headers.forEach(
        (name, values) => headers[name] = values.join(','),
      );
      requests.add(
        _Request(
          request.method,
          request.uri.path,
          request.uri.query,
          headers,
          text.isEmpty ? null : jsonDecode(text),
        ),
      );
      request.response.statusCode = status;
      if (retryAfter != null) {
        request.response.headers.set('retry-after', retryAfter!);
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  FeatureHubFeatureUpdater updater({String? at}) => FeatureHubFeatureUpdater(
    host: at ?? host,
    apiKey: 'default/lingling/kwong*orm',
    headers: const {'x-fwend': 'tofu'},
  );

  group('request', () {
    test('PUT to the feature, with JSON and the extra headers', () async {
      final result = await updater().update(
        'kwong pastry',
        const FeatureUpdate.value('char-siu', lock: false),
      );
      expect(result.success, true);
      final request = requests.single;
      expect(request.method, 'PUT');
      expect(
        request.path,
        '/features/default/lingling/kwong*orm/kwong%20pastry',
      );
      expect(request.query, isEmpty, reason: 'no sdk_version');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.headers['x-fwend'], 'tofu');
      expect(request.headers.containsKey('x-featurehub'), false);
      expect(request.body, {'value': 'char-siu', 'lock': false});
    });

    test('a host query string is kept after the path', () async {
      await updater(
        at: '$host/?region=isaan&sdk_version=9',
      ).update('juad', const FeatureUpdate.lock(true));
      expect(requests.single.path, '/features/default/lingling/kwong*orm/juad');
      expect(requests.single.query, 'region=isaan');
    });

    test('the bodies', () async {
      final u = updater();
      await u.update('juad', const FeatureUpdate.value(true));
      await u.update('juad', const FeatureUpdate.value(26.5));
      await u.update('juad', const FeatureUpdate.clear(lock: false));
      await u.update('juad', const FeatureUpdate.lock(true));
      // a JSON feature's map is sent as its JSON text
      await u.update('juad', const FeatureUpdate.value({'foo': 'หลิงหลิง'}));
      expect(requests.map((r) => r.body), [
        {'value': true},
        {'value': 26.5},
        {'updateValue': true, 'lock': false},
        {'lock': true},
        {'value': '{"foo":"หลิงหลิง"}'},
      ]);
    });
  });

  group('outcomes', () {
    test('each status is its outcome, and none throws', () async {
      const expected = {
        200: FeatureUpdateOutcome.applied,
        201: FeatureUpdateOutcome.applied,
        202: FeatureUpdateOutcome.unchanged,
        400: FeatureUpdateOutcome.invalid,
        403: FeatureUpdateOutcome.forbidden,
        404: FeatureUpdateOutcome.notFound,
        412: FeatureUpdateOutcome.notPossible,
        503: FeatureUpdateOutcome.unavailable,
        500: FeatureUpdateOutcome.failed,
        418: FeatureUpdateOutcome.failed,
      };
      final u = updater();
      for (final MapEntry(key: code, value: outcome) in expected.entries) {
        status = code;
        final result = await u.update('orm', const FeatureUpdate.value('uni'));
        expect(result.outcome, outcome, reason: '$code');
        expect(result.statusCode, code);
        expect(result.success, code == 200 || code == 201 || code == 202);
      }
      // each was sent once: nothing is retried
      expect(requests, hasLength(expected.length));
    });

    test('a 503 gives its Retry-After', () async {
      status = 503;
      retryAfter = '30';
      final result = await updater().update(
        'orm',
        const FeatureUpdate.value('fiona'),
      );
      expect(result.outcome, FeatureUpdateOutcome.unavailable);
      expect(result.retryAfter, const Duration(seconds: 30));
    });

    test('a network error fails, without a status', () async {
      await server.close(force: true);
      final result = await updater().update(
        'orm',
        const FeatureUpdate.value('chago'),
      );
      expect(result.outcome, FeatureUpdateOutcome.failed);
      expect(result.statusCode, isNull);
      expect(result.error, isNotNull);
      expect(result.success, false);
    });
  });

  test('a host and an API key are required', () {
    expect(
      () => FeatureHubFeatureUpdater(host: ' ', apiKey: 'a/b'),
      throwsArgumentError,
    );
    expect(
      () => FeatureHubFeatureUpdater(host: 'http://x', apiKey: ''),
      throwsArgumentError,
    );
  });
}
