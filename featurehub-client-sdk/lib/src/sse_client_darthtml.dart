import 'dart:async';
import 'dart:html';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/config.dart';
import 'package:featurehub_client_sdk/src/sse_client.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'internal_repository.dart';
import 'log.dart';

final _log = Logger('featurehub_io_eventsource');

EdgeStreaming createEdgeStreaming(FeatureHub config, InternalFeatureRepository repository) => WebEdgeStreaming(config, repository);

@internal
class WebEdgeStreaming extends EdgeStreaming {
  String? xFeaturehubHeader;
  EventSource? _es;
  StreamSubscription<Event>? _errorStream;
  List<StreamSubscription<MessageEvent>> _messageEvents = [];

  WebEdgeStreaming(FeatureHub config, InternalFeatureRepository repository): super.create(config, repository);

  void _done() {
    print("got done from error stream");
    repository.notify(SSEResultState.bye);
  }

  void close() {
    if (_errorStream != null) {
      _errorStream?.cancel();
      _errorStream = null;
    }

    _messageEvents.forEach((ms) { ms.cancel(); });
    _messageEvents.clear();

    if (_es != null) {
      _es?.close();
      _es = null;
    }

    closed = true;
    connected = false;
  }

  @override
  Future<void> contextChange(String header) async {
    if (header != xFeaturehubHeader) {
      xFeaturehubHeader = header;
      close();
      repository.repositoryNotReady();
      if (!stopped) {
        await poll();
      }
    }
  }

  /**
   * Keep track of the listener so we can free it
   */
  _listen(String event, void onData(MessageEvent event)) {
    final sub = EventStreamProvider<MessageEvent>(event).forTarget(_es).listen(onData);
    _messageEvents.add(sub);
  }

  @override
  Future<void> poll() async {
    if (connected || stopped) return;

    _log.fine('Connecting to $url');

    final connectedSource = EventSource(url +
        (xFeaturehubHeader == null ? '' : '?xfeaturehub=$xFeaturehubHeader'));

    _errorStream = connectedSource.onError.listen((error) => log.info("connection failed"), cancelOnError: false, onDone: _done, onError: (e) => print("error $e"));
    connectedSource.onOpen.listen((event) {print("event is ${event}, ready state is ${connectedSource.readyState}");});
    _es = connectedSource;

    _listen('features', (msg) => process(SSEResultState.features, msg.data));
    _listen('feature', (msg) => process(SSEResultState.feature, msg.data));
    _listen('bye', (msg) => process(SSEResultState.bye, null));
    _listen('failed', (e) => process(SSEResultState.failure, null));
    _listen('ack', (e) => process(SSEResultState.ack, null));
    _listen('config', (e) => process(SSEResultState.config, e.data));
    _listen('delete_feature', (e) => process(SSEResultState.deleteFeature, e.data));

    connected = true;
  }
}
