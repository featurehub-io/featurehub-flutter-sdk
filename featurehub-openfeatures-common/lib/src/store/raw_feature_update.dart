import 'package:featurehub_client_api/api.dart';

/// The source of updates from FeatureHub Edge (streaming or polling).
const featureHubEdgeSource = 'featurehub-edge';

/// A feature change received by a repository, before any catch and release
/// handling: exactly what arrived, and where from.
///
/// A [ClientFeatureRepository] publishes these on
/// [ClientFeatureRepository.rawFeatureUpdates] so that a store (see
/// [FeatureStore]) can keep a copy of the features, for example to start
/// with them after a restart, or to share them between processes. The
/// [source] lets a store ignore the updates it supplied itself.
sealed class RawFeatureUpdate {
  /// Where the update came from: [featureHubEdgeSource] for FeatureHub,
  /// otherwise the source given to [ClientFeatureRepository.notify] (e.g. a
  /// store replaying the features it holds).
  final String source;

  const RawFeatureUpdate(this.source);
}

/// A complete set of features, replacing all previous ones.
final class FeaturesReceived extends RawFeatureUpdate {
  final List<FeatureState> features;

  const FeaturesReceived(this.features, super.source);

  @override
  String toString() => 'FeaturesReceived(${features.length} from $source)';
}

/// A single feature, added or changed. Prefer [FeatureState.id] to identify
/// it: a feature's key can change.
final class FeatureReceived extends RawFeatureUpdate {
  final FeatureState feature;

  const FeatureReceived(this.feature, super.source);

  @override
  String toString() => 'FeatureReceived(${feature.key} from $source)';
}

/// A feature was deleted. Prefer [FeatureState.id] to identify it.
final class FeatureDeleted extends RawFeatureUpdate {
  final FeatureState feature;

  const FeatureDeleted(this.feature, super.source);

  @override
  String toString() => 'FeatureDeleted(${feature.key} from $source)';
}
