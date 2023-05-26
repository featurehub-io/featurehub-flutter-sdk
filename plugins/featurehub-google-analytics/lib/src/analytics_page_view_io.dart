import 'package:featurehub_google_analytics_plugin/src/analytics_page_view.dart';

BaseAnalyticsPageView createPageView(
        {required String title,
        Map<String, dynamic> additionalParams = const {},
        String? userKey}) =>
    BaseAnalyticsPageView(
        title: title, additionalParams: additionalParams, userKey: userKey);

