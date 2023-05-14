import 'package:featurehub_client_api/api.dart';

import '../internal/internal_features.dart';

class FeatureHubAnalyticsValue {
  final String id;
  final String key;
  final String? value;

  static String? _convert(FeatureStateBaseHolder f) {
    String? line;

    switch (f.type) {
      case null:
        break;
      case FeatureValueType.BOOLEAN:
        line = f.enabled ? 'on' : 'off';
        break;
      case FeatureValueType.STRING:
        line = f.string;
        break;
      case FeatureValueType.NUMBER:
        line = f.number?.toString();
        break;
      case FeatureValueType.JSON:
        line = null;
        break;
    }

    return line;
  }

  FeatureHubAnalyticsValue(FeatureStateBaseHolder holder):
        id = holder.id,
        key = holder.key,
        value = FeatureHubAnalyticsValue._convert(holder);
}

// /// allows us to log an analytics event with this set of features
// void logAnalyticsEvent(String action, {Map<String, Object>? other}) {
//   final featureStateAtCurrentTime =
//   _features.values.where((f) => f.exists).map((f) => f.copy()).toList();
//
//   _analyticsCollectors
//       .add(AnalyticsEvent(action, featureStateAtCurrentTime, other));
// }
