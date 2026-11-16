// A hybrid (VM-side) SSE server for the browser tests. It reports its port,
// then for each request: replies to /features/<key> with a features event and
// then a failure event if the key is "fail", and reports each request's query.
// The first request for the key "slow" is left unanswered. Polling requests
// (GET /features/?apiKey=...) are answered gzip-compressed.
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.autoCompress = false; // polling responses are compressed by hand
  channel.sink.add(server.port);

  var slowSeen = false;
  server.listen((request) async {
    if (request.uri.path.endsWith('/slow') && !slowSeen) {
      slowSeen = true;
      channel.sink.add({'path': request.uri.path, 'hung': true});
      return; // never respond
    }
    channel.sink.add({
      'path': request.uri.path,
      'xfeaturehub': request.uri.queryParameters['xfeaturehub'],
    });

    final response = request.response;
    response.headers.set('Access-Control-Allow-Origin', '*');

    if (request.uri.path == '/features/') {
      channel.sink.add({
        'acceptEncoding': request.headers.value('accept-encoding'),
      });
      response.headers
        ..contentType = ContentType.json
        ..set('content-encoding', 'gzip');
      response.add(
        gzip.encode(
          utf8.encode(
            jsonEncode([
              {
                'id': 'env',
                'features': [
                  {
                    'id': 'fv1',
                    'key': 'colour',
                    'version': 1,
                    'type': 'STRING',
                    'value': 'blue',
                    'l': false,
                  },
                ],
              },
            ]),
          ),
        ),
      );
      await response.close();
      return;
    }

    response.headers.contentType = ContentType('text', 'event-stream');
    response.bufferOutput = false;

    final features = [
      {
        'id': 'fv1',
        'key': 'colour',
        'version': 1,
        'type': 'STRING',
        'value': 'blue',
        'l': false,
      },
    ];
    response.write('event: features\ndata: ${jsonEncode(features)}\n\n');
    await response.flush();

    if (request.uri.path.endsWith('/fail')) {
      response.write('event: failure\ndata: {}\n\n');
      await response.flush();
    }
    // keep the connection open; the browser closes it
  });
}
