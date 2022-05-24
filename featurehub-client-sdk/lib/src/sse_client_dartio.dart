import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:logging/logging.dart';

import 'repository.dart';

final _log = Logger('featurehub_io_eventsource');

/// This listener will stop if we receive a failed message.
class EventSourceRepositoryListener {
  final ClientFeatureRepository _repository;
  StreamSubscription<Event>? _subscription;
  final String _url;
  bool _initialized = false;
  bool _closed = false;
  String? _xFeaturehubHeader;
  StreamController<EventSourceReadyState> _readyStateController = StreamController.broadcast();
  StreamSubscription<EventSourceReadyState>? _readyStateListener;
  EventSource? _es;

  EventSourceRepositoryListener(
      String url, String apiKey, ClientFeatureRepository repository,
      {bool? doInit = true})
      : _repository = repository,
        _url = url + (url.endsWith('/') ? '' : '/') + 'features/' + apiKey {
    if (apiKey.contains('*')) {
      throw Exception(
          'You are using a client evaluated API Key in Dart and this is not supported.');
    }

    if (doInit ?? true) {
      init();
    }

    _readyStateListener = _readyStateController.stream.listen((event) {
      if (event == EventSourceReadyState.CLOSED && _repository.readyness != Readyness.Failed && !_closed) {
        retry();
      }
    });
  }

  Future<void> init() async {
    if (!_initialized) {
      _initialized = true;
      await _repository.clientContext.registerChangeHandler((header) async {
        _xFeaturehubHeader = header;
        if (_subscription != null) {
          retry();
        } else {
          // ignore: unawaited_futures
          _init();
        }
      });
    } else {
      _repository.clientContext
          .build(); // trigger shut and restart via the handler above
    }
  }

  void retry() {
    if (_es == null) {
      _init();
    } else {
      _es!.reopen();
    }
  }

  Future<void> _init() async {
    _closed = false;
    _log.fine('Connecting to $_url');

    _es = await connect(_url);

    _subscription = _es!.listen((event) {
      print('Event is ${event.event} value ${event.data}');
      final readyness = _repository.readyness;
      if (event.event != null) {
        _repository.notify(SSEResultStateExtension.fromJson(event.event),
            event.data == null ? null : jsonDecode(event.data!));
      }
      if (event.event == 'bye' && readyness != Readyness.Failed && !_closed) {
        retry();
      }
    }, onError: (e) {
      print("error $e");
      _repository.notify(SSEResultState.bye, null);
    }, onDone: () {
      print("done");
      if (_repository.readyness != Readyness.Failed && !_closed) {
        _repository.notify(SSEResultState.bye, null);
        retry();
      }
    });
  }

  Future<EventSource> connect(String url) {
    var sourceHeaders = {'content-type': 'application/json'};
    if (_xFeaturehubHeader != null) {
      sourceHeaders['x-featurehub'] = _xFeaturehubHeader!;
    }
    return EventSource.connect(url,
        closeOnLastListener: true, headers: sourceHeaders,
        readyStateController: _readyStateController);
  }

  void close() {
    _closed = true;
    if (_subscription != null) {
      _subscription!.cancel();
      _subscription = null;
    }

    _readyStateListener?.cancel();
  }
}
