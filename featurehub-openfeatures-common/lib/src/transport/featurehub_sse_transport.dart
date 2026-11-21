import '../sse_client.dart'
    if (dart.library.io) '../sse_client_dartio.dart'
    if (dart.library.js_interop) '../sse_client_web.dart';
import 'featurehub_transport.dart';

/// Streams an environment's features from FeatureHub Edge over server-sent
/// events (`<host>/features/<apiKey>`): the transport a connection with a
/// host and an API key uses for [FeatureHubUpdateMode.streaming].
///
/// It uses the platform's SSE client (`featurehub_sse_client` on `dart:io`,
/// the native `EventSource` in browsers; see [EventSourceRepositoryListener]),
/// which reconnects under the target's reconnect policy. For a
/// server-evaluated key the client context is sent (as the `x-featurehub`
/// header, or the `xfeaturehub` query parameter in browsers) and a context
/// change reconnects with the new one by itself.
class FeatureHubSseTransport implements FeatureHubTransport {
  final EventSourceRepositoryListener _listener;

  /// Streams from [FeatureHubTransportTarget.host] with
  /// [FeatureHubTransportTarget.apiKey], which must both be set.
  FeatureHubSseTransport(FeatureHubTransportTarget target)
    : _listener = EventSourceRepositoryListener(
        _required(target.host, 'host'),
        _required(target.apiKey, 'apiKey'),
        target.repository,
        doInit: false,
        reconnectPolicy: target.reconnectPolicy,
        connectTimeout: target.connectTimeout,
        requestTimeout: target.requestTimeout,
        headers: target.headers,
        client: target.httpClient,
      );

  static String _required(String? value, String name) {
    if (value == null) {
      throw ArgumentError('Streaming from FeatureHub requires a $name', name);
    }
    return value;
  }

  @override
  Future<void> start() => _listener.init();

  // the listener reconnects with the new context itself
  @override
  Future<void> contextChanged() async {}

  @override
  Future<void> refreshIfStale() async {}

  @override
  Future<void> close() async => _listener.close();
}
