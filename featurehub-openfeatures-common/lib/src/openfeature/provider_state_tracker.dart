import 'dart:async';

import '../repository.dart';

/// Turns a repository's readiness and feature changes into the OpenFeature
/// provider events the FeatureHub providers emit: stale when the connection
/// is lost, ready again when it recovers, fatal when FeatureHub rejects the
/// API key, stale for good when the environment goes stale (`236` or
/// `edge.stale`), and configuration changed (with the changed flag keys)
/// when features change.
class ProviderStateTracker {
  final ClientFeatureRepository repository;
  final void Function() onStale;
  final void Function() onRecovered;
  final void Function() onFatal;
  final void Function(List<String> flagsChanged) onFlagsChanged;

  /// The environment went stale (see
  /// [ClientFeatureRepository.environmentStale]): reported once, and never
  /// followed by a recovery. Reported after the tracker is created if it
  /// already was.
  final void Function() onEnvironmentStale;
  bool _environmentStale = false;

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
    required this.onEnvironmentStale,
  }) : _versions = _currentVersions(repository) {
    _subscriptions
      ..add(repository.readynessStream.listen(_readinessChanged))
      // delivered asynchronously, so a provider's READY comes first even if
      // the environment was already stale when it initialised
      ..add(
        repository.environmentStaleStream.listen((stale) {
          if (stale && !_environmentStale) {
            _environmentStale = true;
            onEnvironmentStale();
          }
        }),
      )
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
    // a stale environment stays stale: it is never reported as recovered,
    // nor as stale again
    if (_environmentStale && readiness != Readyness.Failed) return;
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
