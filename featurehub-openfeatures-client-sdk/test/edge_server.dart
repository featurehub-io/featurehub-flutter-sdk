// A minimal FeatureHub Edge, run as a hybrid (VM-side) server so the same
// tests can run on the VM and in a browser. It sends the port, then serves
// GET /features?apiKey=... (polling, JSON) and `GET /features/<apiKey>`
// (SSE). The `who` feature is the userkey from the x-featurehub header or
// xfeaturehub query parameter. The first request for an API key ending in
// "slow" is left unanswered.
//
// It also serves your own server's features API, as the server SDK example
// does: `GET /api/features` gives a feature snapshot evaluated for the
// context in the query parameters, with an ETag of them and 304 for a
// matching If-None-Match. Sending it 'log' sends back those requests.
import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart'
    as fh;
import 'package:stream_channel/stream_channel.dart';

import 'support.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  channel.sink.add(server.port);

  var slowSeen = false;
  final log = <Map<String, Object?>>[];
  channel.stream.listen((message) {
    if (message == 'log') channel.sink.add(log);
  });
  server.listen((request) async {
    final apiKey =
        request.uri.queryParameters['apiKey'] ?? request.uri.pathSegments.last;
    if (request.method != 'OPTIONS' && apiKey.endsWith('slow') && !slowSeen) {
      slowSeen = true;
      return; // never respond
    }

    final response = request.response;
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', '*')
      ..set('Access-Control-Expose-Headers', '*');

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    if (request.uri.path == '/api/features') {
      final params = request.uri.queryParametersAll;
      final userkey = params['userkey']?.single;
      // the features as the server SDK's snapshot store would give them for
      // this context (the bundle has no strategies), with an ETag of their
      // versions and the context
      final delivered = bundle(userkey == null ? null : 'userkey=$userkey');
      final repository = fh.ClientFeatureRepository()
        ..notify(SSEResultState.features, delivered);
      final context = fh.mapEvaluationContext({
        for (final MapEntry(:key, :value) in params.entries)
          key: value.length == 1 ? value.single : value,
      }).strategyContext;
      final features = [
        for (final f in delivered)
          if (repository.evaluate(f.key, context: context, interceptors: false)
              case final e)
            FeatureState(
              id: f.id,
              key: f.key,
              l: f.l,
              version: f.version,
              type: f.type,
              value: e.value,
              v: e.strategyId,
            ),
      ];
      repository.shutdown();
      final etag =
          '"${userkey ?? ''}|${features.map((f) => '${f.id}:${f.version}').join('|')}"';
      final ifNoneMatch = request.headers.value('if-none-match');
      final notModified = ifNoneMatch == etag;
      log.add({
        'query': request.uri.query,
        'ifNoneMatch': ifNoneMatch,
        'status': notModified ? 304 : 200,
      });
      response.headers.set('etag', etag);
      if (notModified) {
        response.statusCode = HttpStatus.notModified;
      } else {
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode({
            'features': [for (final f in features) f.toJson()],
          }),
        );
      }
      await response.close();
      return;
    }

    final header =
        request.headers.value('x-featurehub') ??
        request.uri.queryParameters['xfeaturehub'];
    final features = jsonEncode(bundle(header).map((f) => f.toJson()).toList());

    if (request.uri.path == '/features') {
      response.headers.contentType = ContentType.json;
      response.write('[{"id": "env", "features": $features}]');
      await response.close();
      return;
    }

    response.headers.contentType = ContentType('text', 'event-stream');
    response.bufferOutput = false;
    response.write('event: features\ndata: $features\n\n');
    await response.flush();
  });
}
