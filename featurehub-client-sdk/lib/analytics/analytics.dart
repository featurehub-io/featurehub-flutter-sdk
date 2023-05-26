import 'package:featurehub_client_api/api.dart';

import '../src/internal_features.dart';

class FeatureHubAnalyticsValue {
  final String id;
  final String key;
  final String? value;

  static String? _convert(dynamic value, FeatureValueType? type) {
    switch (type) {
      case null: /// its likely a fake value
      case FeatureValueType.STRING:
        return value?.toString();
      case FeatureValueType.BOOLEAN:
        return value == true ? 'on' : 'off';
      case FeatureValueType.NUMBER:
        return value?.toString();
      case FeatureValueType.JSON:
        return null;
    }
  }

  FeatureHubAnalyticsValue(FeatureStateBaseHolder holder):
        id = holder.id,
        key = holder.key,
        value = holder.type == null ? null : FeatureHubAnalyticsValue._convert(holder.analyticsFreeValue, holder.type);

  FeatureHubAnalyticsValue.byValue(this.id, this.key, dynamic value, FeatureValueType type):
      this.value = _convert(value, type);

  static Map<String, dynamic> toJson(FeatureHubAnalyticsValue val) {
    return {
      'id': val.id,
      'feature': val.key,
      'value': val.value
    };
  }
}

