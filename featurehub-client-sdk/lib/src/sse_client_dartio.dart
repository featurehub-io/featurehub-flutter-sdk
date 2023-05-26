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
  StreamSubscription<EventSourceState>? _readyStateListener;
  StreamController<EventSourceState> _readyStateController =
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

    final eventStream = await _connect(url);

    closed = false;
    connected = true;

    _subscription = eventStream.listen((event) {
      log.finest("SSE: received ${event.event}");
      SSEResultState? status;

      try {
        status = SSEResultStateExtension.fromJson(event.event);

        if (status != null) {
          process(status, event.data);
        }
      } catch (e) {
        log.warning("unrecognized status ${event.event}: ${event.data}");
      }
    }, onError: (e) {
      log.warning("error $e");
      repository.repositoryNotReady();
      close();
    }, onDone: () {
      log.finest("SSE: done, checking for re-open");
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

    var receivedFirstConnecting = false;

    // listen for the connection to close and if it didn't fail, re-open it
    _readyStateListener = _readyStateController.stream.listen((event) {
      log.finest("SSE: Ready state ${event}");
      if (event.eq(EventSourceReadyState.CONNECTING)) {
        receivedFirstConnecting = true;
      } else if (event.eq(EventSourceReadyState.CLOSED) &&
          repository.readiness != Readiness.Failed &&
          receivedFirstConnecting &&
          !closed) {
        log.finest("SSE: closed and not failed, so retrying");
        retry();
      }
    });

    log.fine('SSE: connecting to $url with headers:${sourceHeaders}');
    _es = await EventSource.connect(url,
        closeOnLastListener: true,
        headers: sourceHeaders,
        openOnlyOnFirstListener: true,
        readyStateController: _readyStateController);

    return _es!;
  }

  void close() {
    if (!closed) {
      log.fine("SSE: closing");
    }

    closed = true;
    connected = false;

    _subscription?.cancel();
    _subscription = null;

    _xFeaturehubHeader = null;

    // no longer interested in ready state of source
    _readyStateListener?.cancel();
    _readyStateListener = null;
  }

  @override
  // TODO: refactor this out, identical between two
  Future<void> contextChange(String header) async {
    if (header != _xFeaturehubHeader) {
      log.finest("SSE: changing header ${header}");
      close();
      repository.repositoryNotReady();
      _xFeaturehubHeader = header;
      if (!stopped) {
        await poll();
      }
    }
  }
}
