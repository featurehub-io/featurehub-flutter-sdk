// A minimal FeatureHub Edge, run as a hybrid (VM-side) server so the same
// tests can run on the VM and in a browser. It sends the port, then serves
// GET /features/?apiKey=... (polling, JSON) and `GET /features/<apiKey>`
// (SSE). The `who` feature is the userkey from the x-featurehub header or
// xfeaturehub query parameter. The first request for an API key ending in
// "slow" is left unanswered.
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

import 'support.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  channel.sink.add(server.port);

  var slowSeen = false;
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

    final header =
        request.headers.value('x-featurehub') ??
        request.uri.queryParameters['xfeaturehub'];
    final features = jsonEncode(bundle(header).map((f) => f.toJson()).toList());

    if (request.uri.path == '/features/') {
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
