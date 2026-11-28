library;

import "dart:async";
import "dart:convert";

import "package:featurehub_sse_client/featurehub_sse_client.dart";
import "package:featurehub_sse_client/src/limits.dart";
import "package:featurehub_sse_client/src/decoder.dart";
import "package:featurehub_sse_client/src/encoder.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:test/test.dart";

/// event to encode -> wire format
Map<Event, String> _vectors = {
  Event(id: "1", event: "Add", data: "This is a test"):
      "id: 1\nevent: Add\ndata: This is a test\n\n",
  Event(data: "This message, it\nhas two lines."):
      "data: This message, it\ndata: has two lines.\n\n",
};

/// Decodes [input] (optionally split into [chunks]) and returns all events.
Future<List<Event>> _decode(Object input, {EventSourceDecoder? decoder}) {
  final chunks = input is List<String> ? input : [input as String];
  return Stream.fromIterable(chunks)
      .transform(const Utf8Encoder())
      .transform(decoder ?? EventSourceDecoder())
      .toList();
}

const _eventStream = {"content-type": "text/event-stream"};

void main() {
  // these tests reconnect far faster than applications may
  setUpAll(() {
    minReconnectDelay = Duration.zero;
    minServerRetryDelay = Duration.zero;
  });
  tearDownAll(() {
    minReconnectDelay = defaultMinReconnectDelay;
    minServerRetryDelay = defaultMinServerRetryDelay;
  });

  group("encoder", () {
    test("vectors", () {
      var encoder = EventSourceEncoder();
      for (Event event in _vectors.keys) {
        var encoded = _vectors[event]!;
        expect(encoder.convert(event), equals(utf8.encode(encoded)));
      }
    });
    //TODO add gzip test
  });

  group("decoder", () {
    test("vectors", () async {
      for (Event event in _vectors.keys) {
        final decoded = await _decode(_vectors[event]!);
        expect(decoded, hasLength(1));
        expect(decoded.single.id, equals(event.id ?? ""));
        expect(decoded.single.event, equals(event.event ?? "message"));
        expect(decoded.single.data, equals(event.data));
      }
    });

    test("pass retry value", () async {
      var changeRetryValue = expectAsync1((Duration value) {
        expect(value.inMilliseconds, equals(100));
      }, count: 1);
      final decoded = await _decode(
        "id: 1\nevent: Add\ndata: This is a test\nretry: 100\n\n",
        decoder: EventSourceDecoder(retryIndicator: changeRetryValue),
      );
      expect(decoded.single.id, "1");
      expect(decoded.single.event, "Add");
      expect(decoded.single.data, "This is a test");
    });

    test("stream completes when the input completes", () async {
      // toList() would hang forever if done was not propagated
      expect(await _decode("data: a\n\n"), hasLength(1));
    });

    test("errors are propagated", () async {
      final input = Stream<List<int>>.error(StateError("boom"));
      expect(
        input.transform(EventSourceDecoder()).toList(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group("last event id", () {
    test("persists across events that do not set an id", () async {
      final decoder = EventSourceDecoder();
      final events = await _decode(
        "id: 1\ndata: a\n\ndata: b\n\n",
        decoder: decoder,
      );
      expect(events.map((e) => e.id), ["1", "1"]);
      expect(decoder.lastEventId, "1");
    });

    test("an id-only block updates the id but dispatches nothing", () async {
      final decoder = EventSourceDecoder();
      final events = await _decode(
        "id: 1\ndata: a\n\nid: 2\n\n",
        decoder: decoder,
      );
      expect(events, hasLength(1));
      expect(decoder.lastEventId, "2");
    });

    test("comments / heartbeats do not dispatch or clear the id", () async {
      final decoder = EventSourceDecoder();
      final events = await _decode(
        "id: 7\ndata: a\n\n: heartbeat\n\n:\n\n",
        decoder: decoder,
      );
      expect(events, hasLength(1));
      expect(decoder.lastEventId, "7");
    });

    test("an empty id field resets the last event id", () async {
      final decoder = EventSourceDecoder();
      final events = await _decode(
        "id: 1\ndata: a\n\nid\ndata: b\n\n",
        decoder: decoder,
      );
      expect(events.map((e) => e.id), ["1", ""]);
      expect(decoder.lastEventId, "");
    });

    test("an id containing NULL is ignored", () async {
      final decoder = EventSourceDecoder();
      await _decode("id: 1\n\nid: 2\u00003\n\n", decoder: decoder);
      expect(decoder.lastEventId, "1");
    });

    test("an id in an incomplete event is not committed", () async {
      final decoder = EventSourceDecoder();
      await _decode("id: 1\ndata: a\n\nid: 2\ndata: b\n", decoder: decoder);
      expect(decoder.lastEventId, "1");
    });

    test("is seeded from the constructor and survives rebinding", () async {
      final decoder = EventSourceDecoder(lastEventId: "seed");
      var events = await _decode("data: a\n\n", decoder: decoder);
      expect(events.single.id, "seed");

      await _decode("id: 9\ndata: b\n\n", decoder: decoder);
      // simulate a reconnection - same decoder, new stream
      events = await _decode("data: c\n\n", decoder: decoder);
      expect(events.single.id, "9");
    });
  });

  group("field parsing", () {
    test("event type defaults to message", () async {
      final events = await _decode("data: a\n\nevent:\ndata: b\n\n");
      expect(events.map((e) => e.event), ["message", "message"]);
    });

    test("event type does not leak into the next event", () async {
      final events = await _decode("event: x\ndata: a\n\ndata: b\n\n");
      expect(events.map((e) => e.event), ["x", "message"]);
    });

    test("only one leading space is stripped from the value", () async {
      final events = await _decode("data:a\n\ndata:  b\n\n");
      expect(events.map((e) => e.data), ["a", " b"]);
    });

    test("empty data fields still dispatch", () async {
      final events = await _decode("data\n\ndata:\ndata:\n\n");
      expect(events.map((e) => e.data), ["", "\n"]);
    });

    test("a line with no colon is a field with an empty value", () async {
      final events = await _decode("data\ndata\n\n");
      expect(events.single.data, "\n");
    });

    test("unknown fields are ignored", () async {
      final events = await _decode("foo: bar\ndata: a\n\nfoo\n\n");
      expect(events.single.data, "a");
    });

    test("invalid retry values are ignored", () async {
      final retries = <Duration>[];
      final events = await _decode(
        "retry: x\nretry: 10a\nretry:\nretry: 25\ndata: a\n\n",
        decoder: EventSourceDecoder(retryIndicator: retries.add),
      );
      expect(retries, [const Duration(milliseconds: 25)]);
      expect(events, hasLength(1));
    });

    test("CR, LF and CRLF line endings, split across chunks", () async {
      final events = await _decode([
        "data: a\r",
        "\ndata: b\r\rdata: c\n",
        "\nid: 3\r",
        "\ndata: d\r\n\r\n",
      ]);
      expect(events.map((e) => e.data), ["a\nb", "c", "d"]);
      expect(events.last.id, "3");
    });

    test("a leading BOM is ignored", () async {
      final events = await _decode("\uFEFFdata: a\n\n");
      expect(events.single.data, "a");
    });
  });

  group("EventSource", () {
    test("sends Last-Event-ID on reconnection", () async {
      final requests = <http.BaseRequest>[];
      final second = StreamController<List<int>>();
      final reconnected = Completer<void>();

      final client = MockClient.streaming((request, _) async {
        requests.add(request);
        if (requests.length == 1) {
          // a short retry, an event with an id, an event without one, a
          // heartbeat, then the connection fails
          final first = StreamController<List<int>>();
          first.add(
            utf8.encode(
              "retry: 10\nid: 5\ndata: a\n\ndata: b\n\n: heartbeat\n\n",
            ),
          );
          Future.delayed(const Duration(milliseconds: 20), () {
            first.addError(Exception("connection dropped"));
          });
          return http.StreamedResponse(
            first.stream,
            200,
            headers: _eventStream,
          );
        }
        reconnected.complete();
        return http.StreamedResponse(second.stream, 200, headers: _eventStream);
      });

      final es = await EventSource.connect(
        "http://localhost/events",
        client: client,
      );
      final received = <Event>[];
      final sub = es.listen((e) {
        if (e is! EventSourceReconnect) received.add(e);
      });

      await reconnected.future.timeout(const Duration(seconds: 5));

      expect(requests.first.headers.containsKey("Last-Event-ID"), isFalse);
      expect(requests[1].headers["Last-Event-ID"], "5");
      expect(received.map((e) => e.data), ["a", "b"]);
      expect(received.map((e) => e.id), ["5", "5"]);
      expect(es.lastEventId, "5");

      await sub.cancel();
      await second.close();
    });

    test("sends a supplied lastEventId on the first connection", () async {
      final requests = <http.BaseRequest>[];
      final body = StreamController<List<int>>();
      final client = MockClient.streaming((request, _) async {
        requests.add(request);
        return http.StreamedResponse(body.stream, 200, headers: _eventStream);
      });

      await EventSource.connect(
        "http://localhost/events",
        client: client,
        lastEventId: "42",
      );

      expect(requests.single.headers["Last-Event-ID"], "42");
      await body.close();
    });
  });
}
