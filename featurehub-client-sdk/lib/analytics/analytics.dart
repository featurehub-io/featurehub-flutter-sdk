import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';

class FeatureHubAnalyticsValue {
  final String id;
  final String key;
  final String? value;

  static String? _convert(dynamic value, FeatureValueType type) {
    String? line;

    switch (type) {
      case FeatureValueType.BOOLEAN:
        line = value == true ? 'on' : 'off';
        break;
      case FeatureValueType.STRING:
        line = value?.toString();
        break;
      case FeatureValueType.NUMBER:
        line = value?.toString();
        break;
      case FeatureValueType.JSON:
        line = null;
        break;
    }

    return line;
  }

  FeatureHubAnalyticsValue(FeatureStateHolder holder):
        id = holder.id,
        key = holder.key,
        value = holder.type == null ? null : FeatureHubAnalyticsValue._convert(holder.value, holder.type!);

  FeatureHubAnalyticsValue.byValue(this.id, this.key, dynamic value, FeatureValueType type):
      this.value = _convert(value, type);
}

// /// allows us to log an analytics event with this set of features
// void logAnalyticsEvent(String action, {Map<String, Object>? other}) {
//   final featureStateAtCurrentTime =
//   _features.values.where((f) => f.exists).map((f) => f.copy()).toList();
//
//   _analyticsCollectors
//       .add(AnalyticsEvent(action, featureStateAtCurrentTime, other));
// }
