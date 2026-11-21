import 'dart:async';

import '../repository.dart';

/// Why a provider went stale (see [ProviderStateTracker]).
enum StaleCause {
  /// The environment is stale: FeatureHub answered `236` (polling) or sent
  /// `edge.stale` (streaming), and will send no further updates.
  environmentStale,

  /// The source failed for good after features had arrived: a 4xx rejection,
  /// or a browser connection error.
  connectionFailed,
}

/// Turns a repository's changes into the OpenFeature provider events the
/// FeatureHub providers emit once they are ready: configuration changed
/// (with the changed flag keys) when features change, and stale when the
/// features will never be updated again.
///
/// A provider goes stale only on a permanent stop after features have
/// arrived: the environment going stale ([StaleCause.environmentStale],
/// [ClientFeatureRepository.environmentStale]), or the source failing for
/// good ([StaleCause.connectionFailed],
/// [ClientFeatureRepository.connectionFailed]). Not on readiness
/// [Readyness.Stale] by itself, which is also a context change in progress. It is
/// reported once, never recovers, and the provider keeps resolving from the
/// last features. A lost connection that is being re-established (a `bye`)
/// is not reported: the provider stays ready, and the features arrive again
/// when it reconnects. (A failure before any features is an initialization
/// error, handled by the provider, not here.)
class ProviderStateTracker {
  final ClientFeatureRepository repository;

  /// The provider went stale, for good: called at most once.
  final void Function(StaleCause cause) onStale;
  final void Function(List<String> flagsChanged) onFlagsChanged;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Map<String, int> _versions;
  bool _stale = false;

  /// Starts tracking; call once the repository is ready. Events are
  /// delivered asynchronously, so a provider's READY comes first even if the
  /// source had already stopped.
  ProviderStateTracker(
    this.repository, {
    required this.onStale,
    required this.onFlagsChanged,
  }) : _versions = _currentVersions(repository) {
    _subscriptions
      ..add(
        // not readiness: a Stale readiness alone is a context change in
        // progress, which is not a reason to report stale
        repository.connectionFailedStream.listen((failed) {
          if (failed) _goStale(StaleCause.connectionFailed);
        }),
      )
      ..add(
        repository.environmentStaleStream.listen((stale) {
          if (stale) _goStale(StaleCause.environmentStale);
        }),
      )
      ..add(
        // applied changes only: in catch and release mode, caught updates are
        // announced when they are released
        repository.featuresChangedStream.listen((_) => _changed()),
      );
  }

  /// True once the provider has gone stale: its source has stopped for good.
  bool get stale => _stale;

  void _goStale(StaleCause cause) {
    if (_stale) return;
    _stale = true;
    onStale(cause);
  }

  static Map<String, int> _currentVersions(ClientFeatureRepository repo) => {
    for (final fs in repo.featureStates) fs.key: fs.version,
  };

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
