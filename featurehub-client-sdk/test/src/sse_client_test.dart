import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/sse_client.dart';
import 'package:featurehub_sse_client/featurehub_sse_client.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';

import 'mocks.dart';

class SseClientTest extends EdgeStreaming {
  final Stream<Event> mockedSource;
  String? header;
  bool closed = false;
  bool polled = false;

  SseClientTest(FeatureHubConfig config, MockInternalFeatureRepository repository,
      Stream<Event> eventSource)
      : mockedSource = eventSource, super.create(config, repository);

  Future<Stream<Event>> connect(String url) async {
    return mockedSource;
  }

  @override
  void close() {
    closed = true;
  }

  @override
  Future<void> contextChange(String header) async {
    this.header = header;
  }

  @override
  Future<void> poll() async {
    polled = true;
  }

  void process(SSEResultState status, dynamic data) {
    super.process(status, data);
  }
}

void main() {
  late PublishSubject<Event> es;
  late MockInternalFeatureRepository rep;
  late FeatureHubConfig config;
  late SseClientTest sse;

  setUp(() {
    es = PublishSubject<Event>();
    rep = MockInternalFeatureRepository();
    config = MockFeatureHubConfig();
    when(() => config.baseUrl).thenReturn('http://localhost');
    when(() => config.apiKey).thenReturn('1234');
    sse = SseClientTest(config, rep, es);
  });

  test('A failure is reported to the repository and the connection is closed', () {
    sse.process(SSEResultState.failure, null);
    expect(sse.closed, isTrue);
    verify(() => rep.notify(SSEResultState.failure)).called(1);
  });

  test('A bye causes the repository to be not-ready', () {
    sse.process(SSEResultState.bye, null);
    verify(() => rep.notify(SSEResultState.bye)).called(1);
  });
}
