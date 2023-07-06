
import 'package:featurehub_analytics_api/analytics.dart';


class BaseAnalyticsPageView extends UsageEvent implements UsageEventName {
  final Map<String, String> internalParams = {};
  final String title;

  BaseAnalyticsPageView({required this.title, Map<String, dynamic> additionalParams = const {}, String? userKey}) : super(additionalParams: additionalParams, userKey: userKey);

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