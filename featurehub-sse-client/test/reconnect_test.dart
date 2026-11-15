import "dart:async";
import "dart:convert";

import "package:featurehub_sse_client/featurehub_sse_client.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:test/test.dart";

const _ms = Duration(milliseconds: 1);

/// A scripted server: each connection attempt takes the next response from
/// [responses]; once exhausted, the last one is repeated.
class _Server {
  final List<http.StreamedResponse Function()> responses;
  final List<http.BaseRequest> requests = [];
  final List<DateTime> times = [];

  _Server(this.responses);

  late final client = MockClient.streaming((request, _) async {
    requests.add(request);
    times.add(DateTime.now());
    final index = requests.length - 1;
    return responses[index < responses.length ? index : responses.length - 1]();
  });
}

/// A 200 response that sends [body] and then closes the stream (unless
/// [keepOpen]).
http.StreamedResponse Function() _ok(String body, {bool keepOpen = false}) =>
    () {
      final controller = StreamController<List<int>>();
      controller.add(utf8.encode(body));
      if (!keepOpen) {
        Timer(const Duration(milliseconds: 5), controller.close);
      }
      return http.StreamedResponse(controller.stream, 200);
    };

http.StreamedResponse Function() _status(int code) =>
    () => http.StreamedResponse(Stream.value(utf8.encode("nope")), code);

http.StreamedResponse Function() _networkError() =>
    () => throw http.ClientException("connection refused");

/// Waits until [condition] holds, failing after [timeout].
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail("condition not met within $timeout");
    }
    await Future.delayed(const Duration(milliseconds: 2));
  }
}

class _Listener {
  final events = <Event>[];
  final errors = <Object>[];
  late final StreamSubscription<Event> subscription;

  _Listener(EventSource es) {
    subscription = es.listen(events.add, onError: errors.add);
  }

  List<EventSourceReconnect> get reconnects =>
      events.whereType<EventSourceReconnect>().toList();

  List<String?> get messages => events
      .where((e) => e is! EventSourceReconnect)
      .map((e) => e.data)
      .toList();
}

void main() {
  group("ReconnectPolicy", () {
    test("defaults", () {
      const policy = ReconnectPolicy();
      expect(policy.delay, const Duration(seconds: 3));
      expect(policy.serverErrorDelay, const Duration(seconds: 30));
      expect(policy.maxAttempts, isNull);
      expect(policy.shouldRetryStatus(500), isTrue);
      expect(policy.shouldRetryStatus(503), isTrue);
      expect(policy.shouldRetryStatus(400), isFalse);
      expect(policy.shouldRetryStatus(404), isFalse);
      expect(policy.shouldRetryStatus(499), isFalse);
      expect(policy.shouldRetryStatus(204), isFalse);
    });

    test("constant delay by default", () {
      const policy = ReconnectPolicy();
      expect(policy.delayFor(1, _ms * 100), _ms * 100);
      expect(policy.delayFor(5, _ms * 100), _ms * 100);
    });

    test("backoff with a cap", () {
      const policy = ReconnectPolicy(
        backoffMultiplier: 2,
        maxDelay: Duration(milliseconds: 500),
      );
      expect(policy.delayFor(1, _ms * 100), _ms * 100);
      expect(policy.delayFor(2, _ms * 100), _ms * 200);
      expect(policy.delayFor(3, _ms * 100), _ms * 400);
      expect(policy.delayFor(4, _ms * 100), _ms * 500);
    });
  });

  group("EventSource reconnection", () {
    test("reconnects when the server closes the stream", () async {
      final server = _Server([
        _ok("id: 1\ndata: a\n\n"),
        _ok("data: b\n\n", keepOpen: true),
      ]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 10),
        ),
      );
      final listener = _Listener(es);

      await _until(() => listener.messages.length == 2);

      expect(listener.messages, ["a", "b"]);
      expect(listener.reconnects, hasLength(1));
      final reconnect = listener.reconnects.single;
      expect(reconnect.event, "reconnect");
      expect(reconnect.attempt, 1);
      expect(reconnect.delay, _ms * 10);
      expect(reconnect.statusCode, isNull);
      expect(reconnect.error, isNull);
      expect(reconnect.id, "1");
      expect(server.requests[1].headers["Last-Event-ID"], "1");
      expect(es.readyState, EventSourceReadyState.open);
      expect(listener.errors, isEmpty);

      await es.close();
    });

    test("onReconnect only delivers reconnect notifications", () async {
      final server = _Server([
        _ok("event: reconnect\ndata: from the server\n\n"),
        _ok("data: b\n\n", keepOpen: true),
      ]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 5),
        ),
      );
      final reconnects = <EventSourceReconnect>[];
      es.onReconnect.listen(reconnects.add);

      await _until(() => server.requests.length == 2);
      expect(reconnects, hasLength(1));
      expect(reconnects.single.attempt, 1);

      await es.close();
    });

    test("stops on a 4xx response", () async {
      final server = _Server([_ok("data: a\n\n"), _status(404)]);
      final states = StreamController<EventSourceReadyState>.broadcast();
      final seen = <EventSourceReadyState>[];
      states.stream.listen(seen.add);

      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        readyStateController: states,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 5),
        ),
      );
      final listener = _Listener(es);

      await _until(() => listener.errors.isNotEmpty);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(server.requests, hasLength(2), reason: "no retry after a 404");
      final error = listener.errors.single as EventSourceSubscriptionException;
      expect(error.statusCode, 404);
      expect(error.message, "nope");
      expect(es.readyState, EventSourceReadyState.closed);
      expect(seen.last, EventSourceReadyState.closed);
    });

    test(
      "retries 5xx using serverErrorDelay, then resets on success",
      () async {
        final server = _Server([
          _ok("data: a\n\n"),
          _status(503),
          _status(500),
          _ok("data: b\n\n", keepOpen: true),
        ]);
        final es = await EventSource.connect(
          "http://localhost/events",
          client: server.client,
          reconnectPolicy: const ReconnectPolicy(
            delay: Duration(milliseconds: 5),
            serverErrorDelay: Duration(milliseconds: 80),
          ),
        );
        final listener = _Listener(es);

        await _until(() => listener.messages.length == 2);

        expect(
          listener.reconnects.map((r) => [r.attempt, r.statusCode, r.delay]),
          [
            [1, null, _ms * 5],
            [2, 503, _ms * 80],
            [3, 500, _ms * 80],
          ],
        );
        // the 5xx delay was actually waited
        expect(
          server.times[3].difference(server.times[2]),
          greaterThanOrEqualTo(_ms * 75),
        );
        expect(es.reconnectAttempts, 0, reason: "reset by the successful open");
        expect(listener.errors, isEmpty);

        await es.close();
      },
    );

    test("gives up after maxAttempts", () async {
      final server = _Server([_ok("data: a\n\n"), _status(503)]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 5),
          serverErrorDelay: Duration(milliseconds: 5),
          maxAttempts: 2,
        ),
      );
      final listener = _Listener(es);

      await _until(() => listener.errors.isNotEmpty);
      await Future.delayed(const Duration(milliseconds: 50));

      // initial connection + 2 reconnection attempts
      expect(server.requests, hasLength(3));
      expect(listener.reconnects.map((r) => r.attempt), [1, 2]);
      expect(listener.reconnects.map((r) => r.maxAttempts), [2, 2]);
      expect(
        (listener.errors.single as EventSourceSubscriptionException).statusCode,
        503,
      );
      expect(es.readyState, EventSourceReadyState.closed);
    });

    test("retries network errors with the normal delay", () async {
      final server = _Server([
        _ok("data: a\n\n"),
        _networkError(),
        _ok("data: b\n\n", keepOpen: true),
      ]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 5),
          serverErrorDelay: Duration(seconds: 30),
        ),
      );
      final listener = _Listener(es);

      await _until(() => listener.messages.length == 2);

      final failed = listener.reconnects[1];
      expect(failed.statusCode, isNull);
      expect(failed.error, isA<EventSourceSubscriptionException>());
      expect(failed.delay, _ms * 5);

      await es.close();
    });

    test("a server retry field replaces the delay unless disabled", () async {
      for (final honour in [true, false]) {
        final server = _Server([
          _ok("retry: 15\ndata: a\n\n"),
          _ok("data: b\n\n", keepOpen: true),
        ]);
        final es = await EventSource.connect(
          "http://localhost/events",
          client: server.client,
          reconnectPolicy: ReconnectPolicy(
            delay: const Duration(milliseconds: 5),
            honourServerRetry: honour,
          ),
        );
        final listener = _Listener(es);
        await _until(() => listener.messages.length == 2);

        expect(listener.reconnects.single.delay, _ms * (honour ? 15 : 5));
        await es.close();
      }
    });

    test("shouldRetryStatus can be customised", () async {
      final server = _Server([
        _ok("data: a\n\n"),
        _status(429),
        _ok("data: b\n\n", keepOpen: true),
      ]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        reconnectPolicy: ReconnectPolicy(
          delay: const Duration(milliseconds: 5),
          serverErrorDelay: const Duration(milliseconds: 5),
          shouldRetryStatus: (code) =>
              code == 429 || ReconnectPolicy.defaultShouldRetryStatus(code),
        ),
      );
      final listener = _Listener(es);

      await _until(() => listener.messages.length == 2);
      expect(listener.reconnects.last.statusCode, 429);

      await es.close();
    });

    test("ReconnectPolicy.none closes when the stream ends", () async {
      final server = _Server([_ok("data: a\n\n")]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        reconnectPolicy: ReconnectPolicy.none,
      );
      final listener = _Listener(es);

      await _until(() => es.readyState == EventSourceReadyState.closed);
      await Future.delayed(const Duration(milliseconds: 20));

      expect(server.requests, hasLength(1));
      expect(listener.reconnects, isEmpty);
      expect(listener.errors, hasLength(1));
    });

    test("close cancels a pending reconnection", () async {
      final server = _Server([_ok("data: a\n\n")]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        reconnectPolicy: const ReconnectPolicy(
          delay: Duration(milliseconds: 50),
        ),
      );
      final listener = _Listener(es);

      await _until(() => listener.reconnects.isNotEmpty);
      await es.close();
      await Future.delayed(const Duration(milliseconds: 100));

      expect(server.requests, hasLength(1));
      expect(es.readyState, EventSourceReadyState.closed);
      expect(listener.errors, isEmpty);
    });

    test("reopen after close connects again", () async {
      final server = _Server([_ok("data: a\n\n", keepOpen: true)]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
      );
      await es.close();
      await es.reopen();

      expect(server.requests, hasLength(2));
      expect(es.readyState, EventSourceReadyState.open);
      await es.close();
    });
  });

  group("initial connection", () {
    test("throws with the real status code", () async {
      final server = _Server([_status(401)]);
      await expectLater(
        EventSource.connect("http://localhost/events", client: server.client),
        throwsA(
          isA<EventSourceSubscriptionException>().having(
            (e) => e.statusCode,
            "statusCode",
            401,
          ),
        ),
      );
      expect(server.requests, hasLength(1));
    });

    test("network errors throw with status code 0", () async {
      final server = _Server([_networkError()]);
      await expectLater(
        EventSource.connect("http://localhost/events", client: server.client),
        throwsA(
          isA<EventSourceSubscriptionException>()
              .having((e) => e.statusCode, "statusCode", 0)
              .having((e) => e.isHttpError, "isHttpError", false),
        ),
      );
    });

    test("openOnlyOnFirstListener applies the reconnect policy", () async {
      final server = _Server([
        _status(503),
        _ok("data: a\n\n", keepOpen: true),
      ]);
      final es = await EventSource.connect(
        "http://localhost/events",
        client: server.client,
        openOnlyOnFirstListener: true,
        reconnectPolicy: const ReconnectPolicy(
          serverErrorDelay: Duration(milliseconds: 5),
        ),
      );
      expect(server.requests, isEmpty);

      final listener = _Listener(es);
      await _until(() => listener.messages.length == 1);

      expect(listener.reconnects.single.statusCode, 503);
      await es.close();
    });
  });
}
