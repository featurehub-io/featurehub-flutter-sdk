import 'dart:convert';

import 'package:featurehub_client_api/api.dart';

import 'repository.dart';

/// The features a repository holds, with their SHA (see
/// [ClientFeatureRepository.featureSnapshot]): for a server, such as a web
/// application's own API, to pass the features on to its clients, which load
/// them with [ClientFeatureRepository.loadFeatureSnapshot].
///
/// Its JSON form is `{"sha": "...", "features": [<FeatureState>, ...]}`.
class FeatureSnapshot {
  /// The repository's [ClientFeatureRepository.featuresSha] when the
  /// snapshot was taken.
  final String sha;

  /// The features, as delivered by FeatureHub, or evaluated for a context
  /// (without strategies, and with `v` the id of the strategy that matched).
  final List<FeatureState> features;

  const FeatureSnapshot(this.sha, this.features);

  Map<String, dynamic> toJson() => {
    'sha': sha,
    'features': [for (final f in features) f.toJson()],
  };

  /// The snapshot in [data]: a [FeatureSnapshot], its JSON form (a map or a
  /// JSON string), or just the list of features (as [FeatureState]s or their
  /// JSON), whose SHA is then computed. Throws a [FormatException] if [data]
  /// is none of these.
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
      return FeatureSnapshot(
        sha is String ? sha : ClientFeatureRepository.computeSha(features),
        features,
      );
    }

    if (data is List) {
      final features = _features(data);
      return FeatureSnapshot(
        ClientFeatureRepository.computeSha(features),
        features,
      );
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
