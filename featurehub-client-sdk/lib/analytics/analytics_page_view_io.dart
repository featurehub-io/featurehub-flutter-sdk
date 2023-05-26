


import 'analytics_event.dart';

class AnalyticsPageView extends AnalyticsCollectionEvent {
  final Map<String, dynamic> additionalParams;
  final String title;

  AnalyticsPageView({required this.title, this.additionalParams = const {},}) : super(name: 'page_view');

  @override
  Map<String, dynamic> toMap() {
    final map = {
      'page_title': title,
      ...super.toMap(),
      ...additionalParams,
    };
    return map;
  }
}
