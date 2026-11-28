import 'package:http/http.dart' as http;

/// Creates the default HTTP client. [connectTimeout] is only supported on
/// `dart:io`; elsewhere the platform controls it.
http.Client createHttpClient({Duration? connectTimeout}) => http.Client();
