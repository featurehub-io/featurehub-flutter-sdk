import 'dart:async';

import '../repository.dart';

/// Turns a repository's readiness and feature changes into the OpenFeature
/// provider events the FeatureHub providers emit: stale when the connection
/// is lost, ready again when it recovers, fatal when FeatureHub rejects the
/// API key, and configuration changed (with the changed flag keys) when
/// features change.
class ProviderStateTracker {
  final ClientFeatureRepository repository;
  final void Function() onStale;
  final void Function() onRecovered;
  final void Function() onFatal;
  final void Function(List<String> flagsChanged) onFlagsChanged;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Map<String, int> _versions;
  bool _stale = false;

  /// Starts tracking; call once the repository is ready.
  ProviderStateTracker(
    this.repository, {
    required this.onStale,
    required this.onRecovered,
    required this.onFatal,
    required this.onFlagsChanged,
  }) : _versions = _currentVersions(repository) {
    _subscriptions
      ..add(repository.readynessStream.listen(_readinessChanged))
      ..add(
        // applied changes only: in catch and release mode, caught updates are
        // announced when they are released
        repository.featuresChangedStream.listen((_) => _changed()),
      );
  }

  static Map<String, int> _currentVersions(ClientFeatureRepository repo) => {
    for (final fs in repo.featureStates) fs.key: fs.version,
  };

  void _readinessChanged(Readyness readiness) {
    switch (readiness) {
      case Readyness.Ready:
        if (_stale) {
          _stale = false;
          onRecovered();
        }
      case Readyness.NotReady:
        if (!_stale) {
          _stale = true;
          onStale();
        }
      case Readyness.Failed:
        onFatal();
    }
  }

  void _changed() {
    final versions = _currentVersions(repository);
    final changed = <String>{
      for (final e in versions.entries)
        if (_versions[e.key] != e.value) e.key,
      for (final key in _versions.keys)
        if (!versions.containsKey(key)) key,
    };
    _versions = versions;
    if (changed.isNotEmpty) onFlagsChanged(changed.toList());
  }

  Future<void> cancel() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
  }
}
