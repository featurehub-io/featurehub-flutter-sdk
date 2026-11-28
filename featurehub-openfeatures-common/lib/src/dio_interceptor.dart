import 'dart:math';

import 'package:dio/dio.dart';

// this is the standard W3C Trace Context header that most Tracing libraries
// support. https://www.w3.org/TR/trace-context-1/

class W3CTraceContextInterceptor extends InterceptorsWrapper {
  int _startTraceId;
  final int _spanId;

  W3CTraceContextInterceptor()
    : _startTraceId = Random.secure().nextInt(
        1 << 27,
      ), // gives us space to expand
      _spanId = Random.secure().nextInt(1 << 14);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final traceId = _startTraceId.toRadixString(16).padLeft(16, '0');

    _startTraceId++;

    final spanId = _spanId.toRadixString(16).padLeft(8, '0');
    final flags = '01'; // all calls sampled

    options.headers['traceparent'] = '00-$traceId-$spanId-$flags';

    super.onRequest(options, handler);
  }
}
