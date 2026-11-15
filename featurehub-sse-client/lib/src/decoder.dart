library;

import "dart:async";
import "dart:convert";

import "event.dart";

typedef RetryIndicator = void Function(Duration retry);

final RegExp _digitsOnly = RegExp(r"^[0-9]+$");

/// Decodes a `text/event-stream` byte stream into [Event]s, following the
/// WHATWG HTML "Interpreting an event stream" rules.
///
/// The decoder tracks the stream's *last event ID* across events and across
/// successive [bind] calls (i.e. reconnections), so a single instance should
/// be reused for the life of an event source.
class EventSourceDecoder implements StreamTransformer<List<int>, Event> {
  RetryIndicator? retryIndicator;

  /// The last event ID string, as defined by the SSE specification. It is
  /// only updated when an event block is completed (dispatched), and it
  /// persists until the server sends another `id` field. An empty string
  /// means there is no last event ID.
  String lastEventId;

  EventSourceDecoder({this.retryIndicator, String? lastEventId})
    : lastEventId = lastEventId ?? "";

  @override
  Stream<Event> bind(Stream<List<int>> stream) {
    // per-connection parse state
    var data = StringBuffer();
    var hasData = false;
    String? eventType;
    var idBuffer = lastEventId;
    var firstLine = true;

    void dispatch(EventSink<Event> sink) {
      // the id buffer is committed whether or not an event is dispatched
      lastEventId = idBuffer;

      if (hasData) {
        var value = data.toString();
        // remove the single trailing LF added by the last data line
        value = value.substring(0, value.length - 1);
        sink.add(
          Event(
            id: lastEventId,
            event: (eventType == null || eventType!.isEmpty)
                ? "message"
                : eventType,
            data: value,
          ),
        );
      }

      data = StringBuffer();
      hasData = false;
      eventType = null;
    }

    void processField(String field, String value) {
      switch (field) {
        case "event":
          eventType = value;
          break;
        case "data":
          data
            ..write(value)
            ..write("\n");
          hasData = true;
          break;
        case "id":
          if (!value.contains("\u0000")) {
            idBuffer = value;
          }
          break;
        case "retry":
          if (_digitsOnly.hasMatch(value)) {
            retryIndicator?.call(Duration(milliseconds: int.parse(value)));
          }
          break;
        default:
        // unknown fields are ignored
      }
    }

    return stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .transform(
          StreamTransformer<String, Event>.fromHandlers(
            handleData: (String line, EventSink<Event> sink) {
              if (firstLine) {
                firstLine = false;
                // a single leading UTF-8 BOM is ignored
                if (line.startsWith("﻿")) {
                  line = line.substring(1);
                }
              }

              if (line.isEmpty) {
                dispatch(sink);
                return;
              }

              if (line.startsWith(":")) {
                // comment line
                return;
              }

              final colon = line.indexOf(":");
              if (colon < 0) {
                processField(line, "");
                return;
              }

              final field = line.substring(0, colon);
              var value = line.substring(colon + 1);
              if (value.startsWith(" ")) {
                value = value.substring(1);
              }
              processField(field, value);
            },
            handleDone: (EventSink<Event> sink) {
              // an incomplete event at end of stream is discarded
              sink.close();
            },
          ),
        );
  }

  @override
  StreamTransformer<RS, RT> cast<RS, RT>() =>
      StreamTransformer.castFrom<List<int>, Event, RS, RT>(this);
}
