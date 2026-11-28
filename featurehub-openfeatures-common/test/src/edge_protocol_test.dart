// conformance: sdk-version, query-parameter-order, streaming-last-event-id,
// streaming-short-connections, streaming-attempt-reset
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:featurehub_openfeatures_common/featurehub.dart';
import 'package:featurehub_openfeatures_common/src/transport/edge_request.dart';
import 'package:featurehub_openfeatures_common/src/transport/streaming_limits.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart'
    show ReconnectPolicy;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// What a request to [_Edge] carried.
class _Request {
  final Uri uri;
  final String? lastEventId;
  final String? xFeatureHub;

  _Request(HttpRequest request)
    : uri = request.uri,
      lastEventId = request.headers.value('last-event-id'),
      xFeatureHub = request.headers.value('x-featurehub');

  /// The query parameter names, in the order sent.
  List<String> get names => uri.query
      .split('&')
      .where((p) => p.isNotEmpty)
      .map((p) => Uri.decodeQueryComponent(p.split('=').first))
      .toList();
}

/// A FeatureHub Edge whose streaming connections each send [stream]'s events
/// (with `id:` fields), then wait [holdFor] and end with a bye.
class _Edge {
  late HttpServer _server;
  final requests = <_Request>[];

  /// The events each streaming connection sends at once: `features` unless
  /// [quiet] (and the request has a Last-Event-ID).
  bool quiet = false;

  /// How long a streaming connection stays open before its bye.
  Duration holdFor = const Duration(seconds: 30);

  String get host => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  static final _features = jsonEncode([
    {
      'id': 'fv1',
      'key': 'pastry',
      'version': 1,
      'type': 'STRING',
      'value': 'kwong pastry',
      'l': false,
    },
  ]);

  Future<void> _handle(HttpRequest request) async {
    final r = _Request(request);
    requests.add(r);
    final response = request.response;
    if (request.uri.path == '/features') {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode([
          {'id': 'env', 'features': jsonDecode(_features)},
        ]),
      );
      await response.close();
      return;
    }

    response.headers.contentType = ContentType('text', 'event-stream');
    response.bufferOutput = false;
    if (!(quiet && r.lastEventId != null)) {
      response.write('id: 7\nevent: features\ndata: $_features\n\n');
    }
    // Dart's HttpServer sends the headers only with the first data, as a
    // buffering proxy might: a quiet connection then opens only at its bye,
    // and is not short, as short connections are timed from the request
    await response.flush();
    await Future<void>.delayed(holdFor);
    try {
      response.write('event: bye\ndata: {}\n\n');
      await response.close();
    } catch (_) {
      // the client went first
    }
  }
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

void main() {
  late _Edge edge;
  late ClientFeatureRepository repo;

  setUp(() async {
    edge = _Edge();
    await edge.start();
    repo = ClientFeatureRepository();
  });
  tearDown(() async {
    shortConnectionThreshold = defaultShortConnectionThreshold;
    await edge.stop();
  });

  group('the query string', () {
    test('a poll sends apiKey, contextSha and sdk_version, in order', () async {
      final client = FeatureHubRestClient(edge.host, [
        'default/ling*one',
        'default/orm*two',
      ], repo);
      await client.request(force: true);

      final r = edge.requests.single;
      expect(r.names, ['apiKey', 'apiKey', 'contextSha', 'sdk_version']);
      expect(r.uri.queryParametersAll['apiKey'], [
        'default/ling*one',
        'default/orm*two',
      ]);
      expect(r.uri.queryParameters['contextSha'], '0');
      expect(r.uri.queryParameters['sdk_version'], '$edgeSdkVersion');
      expect(edgeSdkVersion, 2);
    });

    test('a server-evaluated poll sends the context as contextSha', () async {
      final client = FeatureHubRestClient(edge.host, ['default/sirilak'], repo);
      repo.clientContext.userKey('lingling kwong').build();
      await _until(() => client.xFeatureHubHeader != null);
      await client.request(force: true);

      final r = edge.requests.single;
      expect(r.xFeatureHub, 'userkey=lingling%20kwong');
      expect(r.uri.queryParameters['contextSha'], _sha(r.xFeatureHub!));
    });

    test(
      'a host keeps its own parameters first, without repeating ours',
      () async {
        final client = FeatureHubRestClient(
          '${edge.host}?tenant=omu%26co&sdk_version=9',
          ['default/ling*one'],
          repo,
        );
        await client.request(force: true);

        final r = edge.requests.single;
        expect(r.names, ['tenant', 'apiKey', 'contextSha', 'sdk_version']);
        expect(r.uri.queryParameters['tenant'], 'omu&co');
        expect(r.uri.queryParametersAll['sdk_version'], ['2']);
      },
    );

    test('a stream sends contextSha then sdk_version', () async {
      final listener = EventSourceRepositoryListener(
        edge.host,
        'default/ling*one',
        repo,
        doInit: false,
      );
      await listener.init();
      await _until(() => repo.readyness == Readyness.Ready);

      final r = edge.requests.single;
      expect(r.uri.path, '/features/default/ling*one');
      expect(r.names, ['contextSha', 'sdk_version']);
      expect(r.uri.queryParameters['contextSha'], '0');
      expect(r.uri.queryParameters['sdk_version'], '2');
      listener.close();
    });

    test('a server-evaluated stream sends its context as contextSha', () async {
      repo.clientContext.userKey('kornaphat');
      final listener = EventSourceRepositoryListener(
        edge.host,
        'default/sirilak',
        repo,
        doInit: false,
      );
      await listener.init();
      await _until(() => repo.readyness == Readyness.Ready);

      final r = edge.requests.last;
      expect(r.xFeatureHub, 'userkey=kornaphat');
      expect(r.uri.queryParameters['contextSha'], _sha('userkey=kornaphat'));
      listener.close();
    });

    test('the browser form adds xfeaturehub last', () {
      final url = EdgeHost('http://edge/?a=1').streamUrl(
        'default/sirilak',
        xFeatureHubHeader: 'userkey=orm',
        xfeaturehub: true,
      );
      expect(
        url,
        'http://edge/features/default/sirilak?a=1'
        '&contextSha=${_sha('userkey=orm')}&sdk_version=2'
        '&xfeaturehub=userkey%3Dorm',
      );
    });
  });

  group('Last-Event-ID', () {
    test('a reconnection after a bye sends it, and quiet connections keep '
        'the features and readiness', () async {
      shortConnectionThreshold = const Duration(milliseconds: 50);
      edge.quiet = true;
      edge.holdFor = const Duration(milliseconds: 100);
      final listener = EventSourceRepositoryListener(
        edge.host,
        'default/ling*one',
        repo,
        doInit: false,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 10),
          maxAttempts: 1,
        ),
      );
      await listener.init();
      await _until(() => edge.requests.length >= 6);

      expect(edge.requests.first.lastEventId, isNull);
      // a bye has no id: field, so the id stays 7
      expect(edge.requests.skip(1).map((r) => r.lastEventId).toSet(), {'7'});
      // healthy quiet connections never use up the attempts
      expect(repo.connectionFailed, isFalse);
      expect(repo.readyness, Readyness.Ready);
      expect(repo.feature('pastry').value, 'kwong pastry');
      listener.close();
    });

    test('a connection for a new context does not send it', () async {
      repo.clientContext.userKey('ling');
      final listener = EventSourceRepositoryListener(
        edge.host,
        'default/sirilak',
        repo,
        doInit: false,
      );
      await listener.init();
      await _until(() => edge.requests.isNotEmpty);
      repo.clientContext.userKey('orm').build();
      await _until(() => edge.requests.length >= 2);

      expect(edge.requests.last.xFeatureHub, 'userkey=orm');
      expect(edge.requests.last.lastEventId, isNull);
      listener.close();
    });
  });

  group('short connections', () {
    test('a stream that ends at once with a bye is a failure, and stops at '
        'the maximum attempts', () async {
      edge.holdFor = Duration.zero;
      final warnings = <String>[];
      final sub = Logger.root.onRecord
          .where((r) => r.level == Level.WARNING)
          .listen((r) => warnings.add(r.message));
      final listener = EventSourceRepositoryListener(
        edge.host,
        'default/ling*one',
        repo,
        doInit: false,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 10),
          maxAttempts: 3,
        ),
      );
      await listener.init();
      await _until(() => repo.connectionFailed);
      await sub.cancel();

      // the first connection and 3 attempts, although each sent features
      // and a bye
      expect(edge.requests, hasLength(4));
      expect(repo.feature('pastry').value, 'kwong pastry');
      expect(warnings.where((w) => w.contains('ended within')), hasLength(1));
      listener.close();
    });
  });
}
