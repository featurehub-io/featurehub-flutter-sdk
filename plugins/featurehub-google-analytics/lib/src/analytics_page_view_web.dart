
import 'dart:html';

import 'analytics_page_view.dart';

BaseAnalyticsPageView createPageView(
    {required String title,
      Map<String, dynamic> additionalParams = const {},
      String? userKey}) =>
    BaseAnalyticsPageView(
        title: title, additionalParams: additionalParams, userKey: userKey)
      .addInternalParams({
      if (window.location.pathname != null)
        'page_path': window.location.pathname!,
      'page_location': window.location.origin,
    })
    ;
