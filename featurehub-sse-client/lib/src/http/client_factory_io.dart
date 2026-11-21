import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Creates the default HTTP client, with [connectTimeout] as the time allowed
/// to establish a connection.
http.Client createHttpClient({Duration? connectTimeout}) =>
    IOClient(HttpClient()..connectionTimeout = connectTimeout);
