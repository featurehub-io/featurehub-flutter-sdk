import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/sse_client.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:meta/meta.dart';

import 'internal_repository.dart';
import 'log.dart';

EdgeStreaming createEdgeStreaming(
        FeatureHub config, InternalFeatureRepository repository) =>
    NativeEdgeStreaming(config, repository);

/// This listener will stop if we receive a failed message.
@internal
class NativeEdgeStreaming extends EdgeStreaming {
  StreamSubscription<Event>? _subscription;
  String? _xFeaturehubHeader;
  EventSource? _es;
  StreamSubscription<EventSourceReadyState>? _readyStateListener;
  StreamController<EventSourceReadyState> _readyStateController =
      StreamController.broadcast();

  NativeEdgeStreaming(FeatureHub config, InternalFeatureRepository repository)
      : super.create(config, repository);

  void retry() {
    if (_es == null) {
      poll();
    } else {
      _es!.reopen();
    }
  }

  @override
  Future<void> poll() async {
    if (connected || stopped) {
      return;
    }

    log.fine('Connecting to $url');

    final eventStream = await _connect(url);

    closed = false;
    connected = true;

    _subscription = eventStream.listen((event) {
      SSEResultState? status;

      try {
        status = SSEResultStateExtension.fromJson(event.event);

        if (status != null) {
          process(status, event.data);
        }
      } catch (e) {
        log.fine("unrecognized status ${event.event}: ${event.data}");
      }
    }, onError: (e) {
      log.warning("error $e");
      repository.repositoryNotReady();
      close();
    }, onDone: () {
      if (repository.readiness != Readiness.Failed && !closed) {
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
      if (event == EventSourceReadyState.CLOSED &&
          repository.readiness != Readiness.Failed &&
          !closed) {
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
    closed = true;
    connected = false;

    if (_subscription != null) {
      _subscription!.cancel();
      _subscription = null;
    }

    _xFeaturehubHeader = null;

    // no longer interested in ready state of source
    _readyStateListener?.cancel();

    _readyStateListener = null;
  }

  @override
  Future<void> contextChange(String header) async {
    if (header != _xFeaturehubHeader) {
      _xFeaturehubHeader = header;
      close();
      await poll();
    }
  }
}
