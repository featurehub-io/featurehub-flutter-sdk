import 'dart:async';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:logging/logging.dart';

import 'features_sha.dart';

final _log = Logger('featurehub_snapshot_store');

/// The source [FeatureSnapshotStore] would give features it loads; it never
/// loads any.
const snapshotStoreSource = 'snapshot-store';

/// Thrown by [FeatureSnapshotStore.featureSnapshot] before the store has any
/// features (a server answers 503).
class FeatureSnapshotNotReady implements Exception {
  final String message;

  const FeatureSnapshotNotReady(this.message);

  @override
  String toString() => 'FeatureSnapshotNotReady: $message';
}

/// A snapshot for one request, and its ETag, which the server sends as it
/// is (only the store knows its clock part).
class ServedSnapshot {
  final FeatureSnapshot snapshot;

  /// `"<sha>"`, or `"<sha>_t<count>"` for an evaluated snapshot whose
  /// features have clock boundaries.
  final String etag;

  const ServedSnapshot(this.snapshot, this.etag);
}

/// Serves your own server's clients the features of its FeatureHub
/// connection, as snapshots (feature-snapshot-protocol.yaml
/// server.snapshot_store): a [FeatureStore] to give the server provider's
/// `stores`, which follows the provider's features and builds each request's
/// [FeatureSnapshot] and ETag ([featureSnapshot], [etagFor]).
///
/// It supplies no features. It keeps its own copy of them as delivered,
/// with their sha and the moments (clock boundaries) at which an evaluated
/// value can change with time alone. It refuses to attach to a
/// server-evaluated API key: FeatureHub sends those features evaluated for
/// the server's own context, so every client would get that context's
/// values; it then has no features, and [featureSnapshot] throws
/// [FeatureSnapshotNotReady].
///
/// With a context, each feature is evaluated for it, by the provider's
/// repository, without value interceptors. With none, the server's code
/// chooses ([featureSnapshot]'s `includeStrategies`): evaluate as for an
/// empty context (the default), or serve the features as delivered,
/// strategies included, for clients that evaluate locally (a provider with
/// `sendContext: false`, the default). A server that leaves the default
/// cannot serve clients that evaluate locally: they send no context, and
/// would get every feature's default value. Serving strategies exposes
/// every strategy and its values, so do it only for trusted clients.
class FeatureSnapshotStore implements FeatureStore {
  final DateTime Function() _clock;

  ClientFeatureRepository? _repository;
  StreamSubscription<RawFeatureUpdate>? _subscription;

  /// The features by id, as delivered.
  final Map<String, FeatureState> _copy = {};
  bool _ready = false;
  String _shaInput = '';

  /// The clock boundaries, sorted, in microseconds since the epoch.
  List<int> _boundaries = const [];

  /// [clock] gives the current time (by default the machine's): tests can fix
  /// it.
  FeatureSnapshotStore({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  @override
  bool get connected => _subscription != null;

  /// True once the store has features to serve: a full set, or features the
  /// repository already held when it attached.
  bool get ready => _ready;

  @override
  Future<void> attach(FeatureStoreTarget target) async {
    if (target.apiKey != null && !target.clientEvaluated) {
      _log.severe(
        'FeatureSnapshotStore: refusing to attach to a server-evaluated API '
        'key: FeatureHub evaluates those features for this server\'s own '
        'context, so every client would get its values. Use a '
        'client-evaluated key (one containing *).',
      );
      return;
    }
    final repository = target.repository;
    _repository = repository;
    // a store attached before this one may already have loaded features
    final held = repository.featureStates.toList();
    if (held.isNotEmpty) _replace(held);
    _subscription = repository.rawFeatureUpdates.listen(_update);
  }

  void _update(RawFeatureUpdate update) {
    if (update.source == snapshotStoreSource) return;
    switch (update) {
      case FeaturesReceived(:final features):
        _replace(features);
      case FeatureReceived(:final feature):
        final held = _copy[feature.id];
        if (held != null &&
            (held.version > feature.version ||
                (held.version == feature.version &&
                    held.value == feature.value &&
                    held.v == feature.v &&
                    held.type == feature.type))) {
          return;
        }
        _copy[feature.id] = feature.copyWith();
        _changed();
      case FeatureDeleted(:final key, :final id):
        final before = _copy.length;
        _copy.removeWhere((fid, f) => id != null ? fid == id : f.key == key);
        if (_copy.length != before) _changed();
    }
  }

  void _replace(Iterable<FeatureState> features) {
    _copy
      ..clear()
      ..addEntries(features.map((f) => MapEntry(f.id, f.copyWith())));
    _ready = true;
    _changed();
  }

  void _changed() {
    _shaInput = featuresShaInput(_copy.values);
    _boundaries = clockBoundaries(_copy.values);
  }

  /// The snapshot for [context] (an OpenFeature evaluation context in map
  /// form; null and empty mean none) and its ETag, at [now] (by default the
  /// store's clock, read once, before anything is evaluated).
  ///
  /// With a context it is evaluated for it, whatever [includeStrategies]
  /// says. With none, it is evaluated as for an empty context unless
  /// [includeStrategies] is true, when the features are given as delivered,
  /// strategies included. Value interceptors are not applied.
  ///
  /// Throws [FeatureSnapshotNotReady] before the store has features, and an
  /// [InvalidContextException] for a context FeatureHub cannot represent.
  ServedSnapshot featureSnapshot({
    Map<String, Object?>? context,
    bool includeStrategies = false,
    DateTime? now,
  }) {
    final time = (now ?? _clock()).toUtc();
    final repository = _repository;
    if (!_ready || repository == null) {
      throw const FeatureSnapshotNotReady('no features yet');
    }
    final mapped = mapEvaluationContext(context ?? const {});
    final asDelivered =
        (context == null || context.isEmpty) && includeStrategies;
    // one consistent view of the copy
    final copy = _copy.values.toList();
    final input = _shaInput;
    final boundaries = _boundaries;

    final List<FeatureState> features;
    if (asDelivered) {
      features = [for (final f in copy) f.copyWith()];
    } else {
      final strategyContext = mapped.strategyContext;
      features = [
        for (final f in copy)
          ?_evaluated(repository, f.key, strategyContext, time),
      ];
    }
    final header = asDelivered ? null : mapped.header;
    final sha = snapshotSha(input, evaluated: !asDelivered, header: header);
    return ServedSnapshot(
      FeatureSnapshot(sha, features),
      _etag(sha, asDelivered ? const [] : boundaries, time),
    );
  }

  /// The ETag [featureSnapshot] would give for the same arguments, without
  /// evaluating anything: for the If-None-Match check.
  ///
  /// Throws as [featureSnapshot] does.
  String etagFor({
    Map<String, Object?>? context,
    bool includeStrategies = false,
    DateTime? now,
  }) {
    final time = (now ?? _clock()).toUtc();
    if (!_ready || _repository == null) {
      throw const FeatureSnapshotNotReady('no features yet');
    }
    final mapped = mapEvaluationContext(context ?? const {});
    final asDelivered =
        (context == null || context.isEmpty) && includeStrategies;
    final sha = snapshotSha(
      _shaInput,
      evaluated: !asDelivered,
      header: asDelivered ? null : mapped.header,
    );
    return _etag(sha, asDelivered ? const [] : _boundaries, time);
  }

  static String _etag(String sha, List<int> boundaries, DateTime now) {
    if (boundaries.isEmpty) return '"$sha"';
    final micros = now.microsecondsSinceEpoch;
    var count = 0;
    while (count < boundaries.length && boundaries[count] <= micros) {
      count++;
    }
    return '"${sha}_t$count"';
  }

  static FeatureState? _evaluated(
    ClientFeatureRepository repository,
    String key,
    StrategyContext context,
    DateTime now,
  ) {
    final evaluated = repository.evaluate(
      key,
      context: context,
      now: now,
      interceptors: false,
    );
    final fs = evaluated.featureState;
    // deleted meanwhile: left out
    if (fs == null) return null;
    return FeatureState(
      id: fs.id,
      key: fs.key,
      l: fs.l,
      version: fs.version,
      type: fs.type,
      value: evaluated.value,
      v: evaluated.strategyId,
      fp: fs.fp == null ? null : Map.of(fs.fp!),
      environmentId: fs.environmentId,
    );
  }

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    _repository = null;
    _copy.clear();
    _ready = false;
    _shaInput = '';
    _boundaries = const [];
  }

  static const _comparing = {
    RolloutStrategyAttributeConditional.EQUALS,
    RolloutStrategyAttributeConditional.NOT_EQUALS,
    RolloutStrategyAttributeConditional.GREATER,
    RolloutStrategyAttributeConditional.GREATER_EQUALS,
    RolloutStrategyAttributeConditional.LESS,
    RolloutStrategyAttributeConditional.LESS_EQUALS,
  };

  static final _date = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');

  /// The moments at which an evaluated value of [features] can change with
  /// the clock alone (feature-snapshot-protocol.yaml
  /// encoding.clock_boundaries), sorted, in microseconds since the epoch:
  /// each fhubWhenActive time (with a conditional that compares against
  /// the clock) and each DATETIME value, to the second, and the next second;
  /// each DATE value's midnight UTC and the next day's.
  static List<int> clockBoundaries(Iterable<FeatureState> features) {
    final boundaries = <int>{};
    void second(DateTime t) {
      final start = truncateToSecond(t.toUtc());
      boundaries
        ..add(start.microsecondsSinceEpoch)
        ..add(start.add(const Duration(seconds: 1)).microsecondsSinceEpoch);
    }

    for (final feature in features) {
      for (final strategy in feature.strategies ?? const []) {
        for (final attr in strategy.attributes) {
          final values = attr.values.whereType<Object>();
          if (attr.fieldName.toLowerCase() == 'fhubwhenactive') {
            if (!_comparing.contains(attr.conditional)) continue;
            for (final v in values) {
              if (parseIsoDateTime(v) case final t?) second(t);
            }
          } else if (attr.type == RolloutStrategyFieldType.DATETIME) {
            for (final v in values) {
              if (parseIsoDateTime(v) case final t?) second(t);
            }
          } else if (attr.type == RolloutStrategyFieldType.DATE) {
            for (final v in values) {
              final match = _date.firstMatch(v.toString());
              if (match == null) continue;
              final day = DateTime.utc(
                int.parse(match[1]!),
                int.parse(match[2]!),
                int.parse(match[3]!),
              );
              boundaries
                ..add(day.microsecondsSinceEpoch)
                ..add(day.add(const Duration(days: 1)).microsecondsSinceEpoch);
            }
          }
        }
      }
    }
    return boundaries.toList()..sort();
  }
}
