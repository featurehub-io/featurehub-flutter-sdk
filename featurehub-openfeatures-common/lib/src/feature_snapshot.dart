import 'dart:convert';

import 'package:featurehub_client_api/api.dart';

/// The features your own server serves its clients (feature-snapshot-protocol
/// encoding.feature_snapshot), with their sha: built by the server SDK's
/// snapshot store, and read by the snapshot client (the transport for a
/// `featuresUrl`).
///
/// Its JSON form is `{"sha": "...", "features": [<FeatureState>, ...]}`.
class FeatureSnapshot {
  /// The snapshot's sha, as the server sent it; null if it sent none (it is
  /// never computed here).
  final String? sha;

  /// The features, as delivered by FeatureHub, or evaluated for a context
  /// (without strategies, and with `v` the id of the strategy that matched).
  final List<FeatureState> features;

  const FeatureSnapshot(this.sha, this.features);

  Map<String, dynamic> toJson() => {
    'sha': ?sha,
    'features': [for (final f in features) f.toJson()],
  };

  /// The snapshot in [data]: a [FeatureSnapshot], its JSON form (a map or a
  /// JSON string), or just the list of features (as [FeatureState]s or their
  /// JSON), which then has no sha. Throws a [FormatException] if [data] is
  /// none of these.
  factory FeatureSnapshot.from(dynamic data) {
    if (data is FeatureSnapshot) return data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException catch (e) {
        throw FormatException('Not a feature snapshot: ${e.message}', data);
      }
    }

    if (data is Map) {
      final features = _features(data['features']);
      final sha = data['sha'];
      return FeatureSnapshot(sha is String ? sha : null, features);
    }

    if (data is List) {
      return FeatureSnapshot(null, _features(data));
    }

    throw FormatException('Not a feature snapshot', data);
  }

  static List<FeatureState> _features(dynamic data) {
    if (data is! List) {
      throw FormatException('A feature snapshot needs a list of features');
    }
    try {
      return [
        for (final f in data)
          f is FeatureState
              ? f
              : FeatureState.fromJson(Map<String, dynamic>.from(f as Map)),
      ];
    } catch (e) {
      if (e is FormatException) rethrow;
      throw FormatException('Not a list of features: $e');
    }
  }

  @override
  String toString() => 'FeatureSnapshot($sha, ${features.length} features)';
}
