import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:http/http.dart' as http;

import 'transport/featurehub_transport.dart' show defaultReconnectPolicy;
import 'repository.dart';

/// The platform-independent API of the SSE listener. The implementation is
/// chosen by conditional export: `sse_client_dartio.dart` (dart:io) or
/// `sse_client_web.dart` (browsers).
///
/// [connectTimeout] limits how long establishing a connection may take
/// (`dart:io` only: browsers control it themselves). [requestTimeout] limits
/// how long each connection attempt waits for the event stream to open; one
/// that times out is retried according to [reconnectPolicy]. Both default to
/// waiting indefinitely.
///
/// [headers] are sent when connecting, and [client] (for example one
/// configured with a proxy) makes the connections; both on `dart:io` only,
/// since a browser's `EventSource` can send neither.
class EventSourceRepositoryListener {
  EventSourceRepositoryListener(
    String url,
    String apiKey,
    ClientFeatureRepository repository, {
    bool? doInit = true,
    ReconnectPolicy reconnectPolicy = defaultReconnectPolicy,
    Duration? connectTimeout,
    Duration? requestTimeout,
    Map<String, String> headers = const {},
    http.Client? client,
  });

  bool get closed => false;

  /// True if the API key is client-evaluated (contains `*`).
  bool get clientEvaluated => false;

  Future<void> init() {
    throw UnimplementedError('This is implemented in the concrete version');
  }

  /// Drops the current connection (if any) and connects again.
  void retry() {
    throw UnimplementedError('This is implemented in the concrete version');
  }

  void close() {
    throw UnimplementedError('This is implemented in the concrete version');
  }
}
