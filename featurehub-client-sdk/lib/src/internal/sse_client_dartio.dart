import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:meta/meta.dart';

import '../config.dart';
import '../features.dart';
import 'internal_repository.dart';
import 'log.dart';

/// This listener will stop if we receive a failed message.
@internal
class EdgeStreaming implements EdgeService {
  final InternalFeatureRepository _repository;
  StreamSubscription<Event>? _subscription;
  final String _url;
  bool _connected = false;
  bool _closed = false;
  bool _stopped = false;
  String? _xFeaturehubHeader;
  EventSource? _es;
  StreamSubscription<EventSourceReadyState>? _readyStateListener;
  StreamController<EventSourceReadyState> _readyStateController = StreamController.broadcast();

  EdgeStreaming(FeatureHub config, this._repository)
      : _url = "${config}/features/${config.apiKey}";

  void retry() {
    if (_es == null) {
      _init();
    } else {
      _es!.reopen();
    }
  }

  bool configEvent(Event event) {
    if (event.data != null && jsonDecode(event.data!)?['edge.stale']) {
      close();
      return true;
    }

    return false;
  }

  void event(Event event) {
    log.fine('Event is ${event.event} value ${event.data}');

    if (event.event == null) {
      return;
    }

    SSEResultState? status;

    try {
      status = SSEResultStateExtension.fromJson(event.event);
    } catch (e) {
      log.fine("unrecognized status");
    }

    if (status == null) {
      return;
    }

    switch (status) {
      case SSEResultState.ack:
      case SSEResultState.bye:
        break;
      case SSEResultState.failure:
        _repository.notify(status);
        break;
      case SSEResultState.features:
        if (event.data != null) {
          _repository.updateFeatures(
              FeatureState.listFromJson(jsonDecode(event.data!)));
        }
        break;
      case SSEResultState.feature:
        if (event.data != null) {
          _repository
              .updateFeature(FeatureState.fromJson(jsonDecode(event.data!)));
        }
        break;
      case SSEResultState.deleteFeature:
        if (event.data != null) {
          _repository
              .deleteFeature(FeatureState.fromJson(jsonDecode(event.data!)));
        }
        break;
      case SSEResultState.config:
        configEvent(event);
        break;
      case SSEResultState.error:
        close();
        _stopped = true;
        break;
    }

    if (event.event == 'bye' &&
        _repository.readiness != Readiness.Failed &&
        !_closed) {
      retry();
    }
  }

  Future<void> _init() async {
    if (_connected) { return; }

    _closed = false;
    log.fine('Connecting to $_url');

    final eventStream = await _connect(_url);

    _connected = true;

    _subscription = eventStream.listen((event) {}, onError: (e) {
      log.warning("error $e");
      _repository.repositoryNotReady();
      close();
    }, onDone: () {
      if (_repository.readiness != Readiness.Failed && !_closed) {
        retry();
      }
    });
  }

  Future<Stream<Event>> _connect(String url) async {
    var sourceHeaders = {'content-type': 'application/json'};
    if (_xFeaturehubHeader != null) {
      sourceHeaders['x-featurehub'] = _xFeaturehubHeader!;
    }

    // listen for the connection to close and if it didn't fail, re-open it
    _readyStateListener = _readyStateController.stream.listen((event) {
      if (event == EventSourceReadyState.CLOSED && _repository.readiness != Readiness.Failed && !_closed) {
        retry();
      }
    });

    _es = await EventSource.connect(url,
        closeOnLastListener: true,
        headers: sourceHeaders,
        readyStateController: _readyStateController);

    return _es!;
  }

  void close() {
    _closed = true;
    _connected = false;

    if (_subscription != null) {
      _subscription!.cancel();
      _subscription = null;
    }

    // no longer interested in ready state of source
    _readyStateListener?.cancel();

    _readyStateListener = null;
  }

  @override
  Future<void> contextChange(String header) async {
    if (header != _xFeaturehubHeader) {
      _xFeaturehubHeader = header;
      close();
      await _init();
    }
  }

  @override
  Future<void> poll() async {
    if (!_connected) {
      await _init();
    }
  }

  @override
  // TODO: implement stopped
  bool get stopped => _stopped;
}
