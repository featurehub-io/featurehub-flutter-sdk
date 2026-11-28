// tests the dart:io SSE listener (test/web/web_test.dart tests the browser one)
@TestOn('vm')
library;

import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';

class _MockStreamEvent extends Mock implements Stream<Event> {}

class _MockRepository extends Mock implements ClientFeatureRepository {
  @override
  final ClientContext clientContext = ClientContext();

  Readyness r = Readyness.Ready;
  bool failed = false;

  @override
  Readyness get readyness => r;

  @override
  bool get connectionFailed => failed;
}

class SseClientTest extends EventSourceRepositoryListener {
  final Stream<Event> mockedSource;

  SseClientTest(
    super.url,
    super.apiKey,
    super.repository,
    Stream<Event> eventSource, {
    super.doInit,
  }) : mockedSource = eventSource;

  Future<Stream<Event>> connect(String url) async {
    return mockedSource;
  }
}

void main() {
  late PublishSubject<Event> es;
  late _MockRepository rep;

  setUp(() {
    es = PublishSubject<Event>();
    rep = _MockRepository();

    SseClientTest('', '', rep, es);
  });

  test('A proper message is delivered to the repository', () {
    es.listen(
      expectAsync1((_) {
        verify(() => rep.notify(SSEResultState.failure, any())).called(1);
      }),
    );

    es.add(Event(event: SSEResultState.failure.name, data: '{}'));
  });

  test('A failure is reported to the repository', () {
    es.listen(
      (value) {},
      onError: expectAsync1((dynamic _) {
        // the event source only errors once it has stopped for good
        verify(() => rep.notify(SSEResultState.failure, any()));
      }),
    );
    es.addError('blah');
  });

  // this one is an endless loop

  // test('Closure of stream is reported to repository', () {
  //   es.listen((value) {}, onDone: expectAsync0(() {
  //     verify(rep.notify(SSEResultState.bye, any));
  //   }));
  //
  //   es.close();
  // });

  test('Closing unlistens to the stream', () async {
    final stream = _MockStreamEvent();
    final sub = _MockSubscription();
    rep = _MockRepository();

    when(
      () => stream.listen(
        any(),
        onError: any(named: 'onError'),
        onDone: any(named: 'onDone'),
      ),
    ).thenReturn(sub);

    // cancel is called, it has to return a future void
    final c = Completer<void>();
    when(() => sub.cancel()).thenAnswer((_) => c.future);
    c.complete();

    final sse = SseClientTest('', '', rep, stream, doInit: false);
    await sse.init();

    sse.close();

    verify(() => sub.cancel()).called(1);
  });

  group('reconnection is left to the event source', () {
    late PublishSubject<Event> stream;
    late _MockRepository repo;
    late SseClientTest listener;

    Future<void> pump() => Future.delayed(Duration.zero);

    setUp(() async {
      stream = PublishSubject<Event>();
      repo = _MockRepository();
      listener = SseClientTest('', '', repo, stream, doInit: false);
      await listener.init();
      await pump();
    });

    test('a reconnect notification marks the repository not ready', () async {
      stream.add(
        EventSourceReconnect(
          attempt: 1,
          maxAttempts: null,
          delay: Duration(seconds: 3),
        ),
      );
      await pump();

      verify(() => repo.notify(SSEResultState.bye, null)).called(1);
      expect(listener.closed, false);
      expect(stream.hasListener, true);
    });

    test('a reconnect is not reported once the connection failed', () async {
      repo.failed = true;
      stream.add(
        EventSourceReconnect(
          attempt: 1,
          maxAttempts: null,
          delay: Duration(seconds: 3),
        ),
      );
      await pump();

      verifyNever(() => repo.notify(any(), any()));
    });

    test('a failure from the server closes the connection', () async {
      repo.failed = true; // what the repository does on failure
      stream.add(Event(event: SSEResultState.failure.name, data: '{}'));
      await pump();

      verify(() => repo.notify(SSEResultState.failure, any())).called(1);
      expect(listener.closed, true);
      expect(stream.hasListener, false);
    });

    test('a bye does not close the connection', () async {
      stream.add(Event(event: SSEResultState.bye.name, data: '{}'));
      await pump();

      verify(() => repo.notify(SSEResultState.bye, any())).called(1);
      expect(listener.closed, false);
      expect(stream.hasListener, true);
    });

    test('a stale edge closes the connection, reporting it', () async {
      stream.add(Event(event: 'config', data: '{"edge.stale": true}'));
      await pump();

      verify(() => repo.markEnvironmentStale()).called(1);
      verifyNever(() => repo.notify(SSEResultState.bye, any()));
      expect(listener.closed, true);
      expect(stream.hasListener, false);
    });

    test('unknown event types are ignored', () async {
      stream.add(Event(event: 'message', data: 'not json'));
      await pump();

      verifyNever(() => repo.notify(any(), any()));
    });

    test('giving up on a 4xx is reported as a failure', () async {
      stream.addError(EventSourceSubscriptionException(401, 'unauthorised'));
      await pump();

      verify(() => repo.notify(SSEResultState.failure, null)).called(1);
    });

    // the event source only gives up for good: nothing reconnects after it,
    // so whatever the cause it is a permanent failure (the provider goes stale
    // after features, or fails to initialize before them)
    test('giving up for any other reason is a failure too', () async {
      // e.g. a status a custom policy does not retry, or no attempts left
      stream.addError(EventSourceSubscriptionException(503, 'unavailable'));
      await pump();

      verify(() => repo.notify(SSEResultState.failure, null)).called(1);
      verifyNever(() => repo.notify(SSEResultState.bye, any()));
    });

    test('running out of attempts is a failure', () async {
      stream.addError(
        EventSourceSubscriptionException(
          0,
          'connection closed and reconnection attempts exhausted',
        ),
      );
      await pump();

      verify(() => repo.notify(SSEResultState.failure, null)).called(1);
    });
  });

  test('a context change reconnects with the new header', () async {
    final streams = <PublishSubject<Event>>[];
    final rep = _MockRepository();
    final listener = _RecordingSseClient('', '', rep, streams);
    await listener.init();
    await Future.delayed(Duration.zero);
    expect(streams, hasLength(1));
    expect(listener.headers, [null]);

    rep.clientContext.userKey('fred').build();
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero);

    expect(streams, hasLength(2));
    expect(streams.first.hasListener, false, reason: 'old connection dropped');
    expect(streams.last.hasListener, true);
    expect(listener.headers.last, contains('fred'));
  });

  test('once closed, a context change or retry does not reconnect', () async {
    final streams = <PublishSubject<Event>>[];
    final rep = _MockRepository();
    final listener = _RecordingSseClient('', '', rep, streams);
    await listener.init();
    await Future.delayed(Duration.zero);
    expect(streams, hasLength(1));

    listener.close();
    rep.clientContext.userKey('kornaphat').build();
    listener.retry();
    await Future.delayed(const Duration(milliseconds: 20));

    expect(streams, hasLength(1), reason: 'no new connection');
    expect(streams.single.hasListener, false);
    expect(listener.closed, true);
  });

  test('quick context changes keep only the latest connection', () async {
    final streams = <PublishSubject<Event>>[];
    final rep = _MockRepository();
    final listener = _RecordingSseClient(
      '',
      '',
      rep,
      streams,
      connectDelay: const Duration(milliseconds: 20),
    );
    await listener.init();

    // the next context changes before the previous connection has opened
    rep.clientContext.userKey('anne').build();
    await Future.delayed(const Duration(milliseconds: 5));
    rep.clientContext.userKey('bob').build();
    await Future.delayed(const Duration(milliseconds: 100));

    final listened = [
      for (var i = 0; i < streams.length; i++)
        if (streams[i].hasListener) listener.headers[i],
    ];
    expect(listened, hasLength(1));
    expect(listened.single, contains('bob'));
  });
}

/// Hands out a new stream for every connection and records the context
/// header that was in effect.
class _RecordingSseClient extends EventSourceRepositoryListener {
  final List<PublishSubject<Event>> streams;
  final List<String?> headers = [];

  final ClientFeatureRepository repository;

  final Duration connectDelay;

  _RecordingSseClient(
    String url,
    String apiKey,
    this.repository,
    this.streams, {
    this.connectDelay = Duration.zero,
  }) : super(url, apiKey, repository, doInit: false);

  // not @override: the analyzer resolves the conditional export to the stub
  // listener, but at runtime this overrides the dart:io connect()
  Future<Stream<Event>> connect(String url) async {
    headers.add(repository.clientContext.generateHeader());
    final stream = PublishSubject<Event>();
    streams.add(stream);
    if (connectDelay > Duration.zero) await Future.delayed(connectDelay);
    return stream;
  }
}

class _MockSubscription extends Mock implements StreamSubscription<Event> {}
