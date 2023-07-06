import 'package:featurehub_client_api/api.dart';

import '../src/internal_features.dart';

class FeatureHubUsageValue {
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

  FeatureHubUsageValue(FeatureStateBaseHolder holder):
        id = holder.id,
        key = holder.key,
        value = holder.type == null ? null : FeatureHubUsageValue._convert(holder.usageFreeValue, holder.type);

  FeatureHubUsageValue.byValue(this.id, this.key, dynamic value, FeatureValueType type):
      this.value = _convert(value, type);

  static Map<String, dynamic> toJson(FeatureHubUsageValue val) {
    return {
      'id': val.id,
      'feature': val.key,
      'value': val.value
    };
  }
}

