
import 'package:featurehub_analytics_api/analytics.dart';

import 'analytics_page_view_io.dart'
  if (dart.library.html)  'analytics_page_view_web.dart';

abstract class BaseAnalyticsPageView extends AnalyticsEvent implements AnalyticsEventName {
  final Map<String, String> internalParams = {};
  final String title;

  factory BaseAnalyticsPageView({required String title, Map<String,
      dynamic> additionalParams = const {}, String? userKey }) => createPageView(title: title, additionalParams: additionalParams, userKey: userKey );

  BaseAnalyticsPageView.create({required this.title, Map<String, dynamic> additionalParams = const {}, String? userKey}) : super(additionalParams: additionalParams, userKey: userKey);

  BaseAnalyticsPageView addInternalParams(Map<String, String> params) {
    internalParams.addAll(params);
    return this;
  }

  String get eventName => 'page_view';

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