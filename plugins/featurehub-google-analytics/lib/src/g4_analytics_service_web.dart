import 'dart:async';
import 'dart:convert';
import 'dart:html'; // ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js; // ignore: avoid_web_libraries_in_flutter

import 'package:featurehub_analytics_api/analytics.dart';
import 'package:logging/logging.dart';
import 'g4_analytics_service.dart';

final _urlTemplate = Uri.parse('https://www.googletagmanager.com/gtag/js');
// const _eventNameParam = 'eventName';

/// The global JS function to submit analytics data.
const _function = 'gtag';

var _logger = Logger("google-tag");

G4AnalyticsService createGoogleAnalytics4Service({
  String? measurementId,
  String? apiKey,
  bool  debugMode = false,
  bool unnamedBecomeEventParameters = false
}) =>
    GoogleAnalytics4ServiceWeb(measurementId: measurementId, debugMode: debugMode, unnamedBecomeEventParameters: unnamedBecomeEventParameters);

/// Submits data to a Google Analytics 4 property using JavaScript.
class GoogleAnalytics4ServiceWeb extends G4AnalyticsService {
  final String? measurementId;
  final _readyCompleter = Completer<void>();
  final bool debugMode;

  GoogleAnalytics4ServiceWeb({
    required this.measurementId,
    required this.debugMode,
    bool unnamedBecomeEventParameters = false
  }) : super.create(unnamedBecomeEventParameters: unnamedBecomeEventParameters) {
    if (this.measurementId != null)
      _loadGoogleJs();
  }

  void _loadGoogleJs() {
    final url = _urlTemplate.replace(queryParameters: {'id': measurementId});
    final gtagSrc = url.toString();

    if (document.querySelectorAll("head script[src='${gtagSrc}']").isEmpty) {
      // Replicating the JS from the installation manual for websites.
      _evalJs('window.dataLayer = window.dataLayer || [];');
      _evalJs('window.$_function = function () { dataLayer.push(arguments); }');
      _logJsDate();
      _logConfig();

      final element = document.createElement('script') as ScriptElement;
      element.async = true;
      element.src = gtagSrc; // ignore: unsafe_html
      element.onLoad.listen(_readyCompleter.complete);
      document.head!.append(element);
    }
  }

  static dynamic _evalJs(String code) {
    _logger.finer('JS eval: $code');
    return js.context.callMethod('eval', [code]);
  }

  void _logJsDate() {
    _logEncoded('js', 'new Date()');
  }

  void _logConfig() {
    _log('config', [measurementId, { 'debug_mode':  debugMode }] );
  }

  void _log(String command, List<Object?> arguments) {
    _logEncoded(command, arguments.map(jsonEncode).join(','));
  }

  void _logEncoded(String command, String arguments) {
    _evalJs('$_function(${jsonEncode(command)}, $arguments)');
  }

  @override
  Future<void> sendProtected(AnalyticsEvent event) async {
    await _readyCompleter.future;

    if (event is AnalyticsEventName) {
      // Google Analytics cannot use event names as a dimension,
      // so also add the event name as a parameter.
      final params = {
        ...defaultEventParameters,
        ...event.toMap(),
      };

      // cull if there are too many
      while (params.length > 25) {
        params.remove(params.keys.first);
      }

      _log('event', [(event as AnalyticsEventName).eventName, params]);
    }
  }
}
