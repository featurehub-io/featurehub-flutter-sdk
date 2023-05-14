import 'dart:async';
import 'dart:convert';
import 'dart:html';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/src/config.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'internal_repository.dart';

final _log = Logger('featurehub_io_eventsource');

@internal
class EdgeStreaming implements EdgeService {
  final InternalFeatureRepository _repository;
  StreamSubscription<Event>? _subscription;
  final String _url;
  bool _connected = false;
  String? xFeaturehubHeader;
  bool _stopped = false;
  EventSource? es;

  EdgeStreaming(FeatureHub config, this._repository)
      : _url = "${config}/features/${config.apiKey}";

  bool get closed => es == null;

  void _done() {
    _repository.notify(SSEResultState.bye);
  }

  void _error(event) {
    _log.severe('Lost connection to feature repository ${event ?? 'unknown'}');
  }

  void _configMessage(MessageEvent msg) {
    _log.fine('received config event ${msg.data}');

    if (msg.data != null) {
      final config = jsonDecode(msg.data);
      if (config['edge.stale']) {
        _stopped = true;
        close();
        _esClose();
      }
    }
  }

  EventSource _connect(String url) {
    return EventSource(url +
        (xFeaturehubHeader == null ? '' : '?xfeaturehub=$xFeaturehubHeader'));
  }

  void close() {
    if (_subscription != null) {
      _subscription!.cancel();
      _subscription = null;
    }
  }

  void _esClose() {
    es?.close();
    es = null;
    _connected = false;
    if (!_stopped) {
      poll();
    }
  }

  @override
  Future<void> contextChange(String header) async {
    if (header != xFeaturehubHeader) {
      xFeaturehubHeader = header;
      _esClose(); // this will poll immediately
    }
  }

  @override
  Future<void> poll() async {
    if (_connected) return;

    _log.fine('Connecting to $_url');

    es = _connect(_url)
      ..onError.listen(_error, cancelOnError: true, onDone: _done);

    EventStreamProvider<MessageEvent>('features').forTarget(es).listen((msg) {
      _repository.updateFeatures(FeatureState.listFromJson(jsonDecode(msg.data)));
    });
    EventStreamProvider<MessageEvent>('feature').forTarget(es).listen((msg) {
      _repository.updateFeature(FeatureState.fromJson(jsonDecode(msg.data)));
    });
    EventStreamProvider<MessageEvent>('bye').forTarget(es).listen((msg) {});
    EventStreamProvider<MessageEvent>('failed').forTarget(es).listen((e) {
      _repository.notify(SSEResultState.failure);
      _log.warning('Failed connection to server, disconnecting');
      _esClose();
    });
    EventStreamProvider<MessageEvent>('ack').forTarget(es).listen((msg) {});
    EventStreamProvider<MessageEvent>('config')
        .forTarget(es)
        .listen(_configMessage);
    EventStreamProvider<MessageEvent>('delete_feature')
        .forTarget(es)
        .listen((msg) => _repository.deleteFeature(FeatureState.fromJson(jsonDecode(msg.data))));
  }

  @override
  bool get stopped => _stopped;
}
