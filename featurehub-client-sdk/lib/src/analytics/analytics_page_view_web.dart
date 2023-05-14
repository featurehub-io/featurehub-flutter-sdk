
import 'dart:html';

import 'package:featurehub_client_sdk/src/analytics/analytics_event.dart';

class AnalyticsPageView extends AnalyticsEvent {
  final Map<String, dynamic> additionalParams;
  late Map<String, String> internalParams;
  final String title;

  AnalyticsPageView({required this.title, this.additionalParams = const {},}) : super(name: 'page_view') {
    internalParams = {
        if (window.location.pathname != null)
          'page_path': window.location.pathname!,
        'page_location': window.location.origin,
    };
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      'page_title': title,
      ...internalParams,
      ...super.toMap(),
      ...additionalParams,
    };
  }
}
