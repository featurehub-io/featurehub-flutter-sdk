import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

/// A repository's readiness.
///
/// - [NotReady]: no features are held.
/// - [Ready]: features are held and are current (for the current context,
///   from a live source).
/// - [Stale]: features are held and keep being resolved, but may not be
///   current: a context change is in progress, or the source has stopped for
///   good ([ClientFeatureRepository.connectionFailed],
///   [ClientFeatureRepository.environmentStale]).
/// - [Failed]: final; the connection failed before any features were
///   received.
///
/// Ready never goes straight to NotReady (clearing goes Ready, Stale,
/// NotReady), NotReady never goes to Stale, and once a full set of features
/// has been received nothing makes readiness Failed.
// public API; kept as-is rather than renamed to lowerCamelCase
// ignore: constant_identifier_names
enum Readyness { NotReady, Ready, Stale, Failed }

abstract class FeatureStateHolder {
  bool get exists;
  bool? get booleanValue;
  String? get stringValue;
  num? get numberValue;
  String? get key;
  dynamic get jsonValue;
  FeatureValueType? get type;

  dynamic get value;

  int? get version;

  Stream<FeatureStateHolder> get featureUpdateStream;

  bool get isSet;
  bool get isEnabled;
  FeatureStateHolder copy();
}

/// An interceptor's answer for a feature: whether it supplies the value, and
/// the value it supplies.
class ValueMatch {
  final bool matched;

  /// The value: a bool, num or String (JSON features as a JSON string), or
  /// null for no value. Strings are converted to the type the flag is
  /// resolved as, so `'true'` resolves as a boolean and `'7'` as a number.
  final Object? value;

  const ValueMatch(this.matched, this.value);

  /// The interceptor does not supply this feature's value.
  static const ValueMatch none = ValueMatch(false, null);
}

/// Supplies feature values in place of those from FeatureHub, for example
/// local overrides during development. Register one with
/// [ClientFeatureRepository.addValueInterceptor], or give it to a provider's
/// `interceptors`.
///
/// The first registered interceptor that matches a feature supplies its
/// value.
abstract class ValueInterceptor {
  /// Whether this interceptor supplies the value of the feature [key].
  /// [featureState] is the feature as FeatureHub delivered it (null if it
  /// has not delivered it), so the value can match the feature's type.
  ValueMatch matched(String key, FeatureState? featureState);

  /// Releases any resources the interceptor holds.
  void close() {}
}

class _InterceptorHolder {
  final bool allowLockOverride;
  final ValueMatch Function(String key, FeatureState? featureState) match;
  final ValueInterceptor? interceptor;

  _InterceptorHolder(this.allowLockOverride, this.match, [this.interceptor]);
}

typedef FeatureValueInterceptor = ValueMatch Function(String? key);

class _FeatureStateBaseHolder implements FeatureStateHolder {
  dynamic _value;
  FeatureState? _featureState;
  BehaviorSubject<FeatureStateHolder>? _listeners;
  final ClientFeatureRepository _repo;

  List<_InterceptorHolder> get featureValueInterceptors =>
      _repo._featureValueInterceptors;

  @override
  String? get key => _featureState?.key;
  @override
  Stream<FeatureStateHolder> get featureUpdateStream => _listeners!.stream;

  _FeatureStateBaseHolder(_FeatureStateBaseHolder? fs, this._repo) {
    _listeners = fs?._listeners ?? BehaviorSubject<FeatureStateHolder>();
  }

  @override
  dynamic get value => _current;

  @override
  bool get isSet => _current != null;

  @override
  bool get isEnabled =>
      _featureState?.type == FeatureValueType.BOOLEAN && _current == true;

  /// The feature's value for the repository's [ClientContext]: the value of
  /// the first matching rollout strategy if the feature has any (only sent
  /// for client-evaluated API keys), otherwise its default value.
  dynamic get _current {
    final fs = _featureState;
    if (fs == null) return _value;
    final strategies = fs.strategies;
    if (strategies == null || strategies.isEmpty) return _value;
    final applied = _repo.applyFeature.apply(
      strategies,
      fs.key,
      fs.id,
      _repo.clientContext,
    );
    return applied.matched ? applied.value : _value;
  }

  set featureState(FeatureState fs) {
    _featureState = fs;
    final oldValue = _value;
    _value = fs.value;
    if (oldValue != _value) {
      _listeners!.add(this);
    }
  }

  @override
  int? get version => _featureState?.version;

  @override
  bool get exists => _findIntercept(() => _current) != null;

  // interceptors may supply strings (e.g. from a dotenv file), which are
  // converted to the type asked for

  @override
  bool? get booleanValue => switch (_findIntercept(
    () => _featureState?.type == FeatureValueType.BOOLEAN ? _current : null,
  )) {
    final bool b => b,
    final String s => s.toLowerCase() == 'true',
    _ => null,
  };

  @override
  String? get stringValue => switch (_findIntercept(
    () =>
        (_featureState?.type == FeatureValueType.STRING ||
            _featureState?.type == FeatureValueType.JSON)
        ? _current
        : null,
  )) {
    null => null,
    final Object v => '$v',
  };

  @override
  num? get numberValue => switch (_findIntercept(
    () => _featureState?.type == FeatureValueType.NUMBER ? _current : null,
  )) {
    final num n => n,
    final String s => num.tryParse(s.trim()),
    _ => null,
  };

  @override
  dynamic get jsonValue {
    final body = _findIntercept(
      () => _featureState?.type == FeatureValueType.JSON ? _current : null,
    );

    return body is String ? jsonDecode(body) : body;
  }

  @override
  FeatureValueType? get type => _featureState!.type;

  @override
  FeatureStateHolder copy() {
    return _FeatureStateBaseHolder(null, _repo)..featureState = _featureState!;
  }

  dynamic _findIntercept(Function determineDefault) {
    final locked = _featureState != null && true == _featureState!.l;

    final k = key;
    if (k != null) {
      for (final vi in featureValueInterceptors) {
        if (locked && !vi.allowLockOverride) continue;
        final vm = vi.match(k, _featureState);
        if (vm.matched) return vm.value;
      }
    }
    return determineDefault();
  }

  void shutdown() {
    _listeners!.close();
  }
}

final _log = Logger('FeatureHub');

class ClientFeatureRepository {
  bool _hasReceivedInitialState = false;
  // indexed by key
  final Map<String?, _FeatureStateBaseHolder> _features = {};
  Readyness _readynessState = Readyness.NotReady;
  final _readynessListeners = BehaviorSubject<Readyness>.seeded(
    Readyness.NotReady,
  );
  final _newFeatureStateAvailableListeners =
      PublishSubject<ClientFeatureRepository>();
  final _featuresChangedListeners = PublishSubject<ClientFeatureRepository>();
  final _rawUpdates = StreamController<RawFeatureUpdate>.broadcast();
  bool _catchAndReleaseMode = false;

  /// True once the first set of features from FeatureHub, or a failure, has
  /// arrived. Catch and release mode only takes effect after that, so it can
  /// be switched on before connecting without holding back the initial
  /// features or hiding the initial readiness. Features loaded from a store
  /// do not count: FeatureHub's first features replace them as normal.
  bool _initialStateResolved = false;

  /// The keys of a full set of features held back in catch and release mode
  /// (with any single features held back after it): on [release], features
  /// not among them are removed.
  Set<String>? _caughtFullSetKeys;

  bool get _catchActive => _catchAndReleaseMode && _initialStateResolved;

  String _featuresSha = computeSha(const []);
  // indexed by id (not key)
  final Map<String?, FeatureState> _catchReleaseStates = {};
  final List<_InterceptorHolder> _featureValueInterceptors = [];
  final ClientContext clientContext = ClientContext();

  /// Evaluates rollout strategies for client-evaluated API keys.
  final ApplyFeature applyFeature;

  ClientFeatureRepository({this.applyFeature = const ApplyFeature()});

  Stream<Readyness> get readynessStream => _readynessListeners.stream;

  final _environmentStaleListeners = BehaviorSubject<bool>.seeded(false);

  /// True once the source has said the environment is stale: FeatureHub
  /// answered `236`, or sent `config` with `edge.stale`. The features held
  /// are the last there will be: they stay usable (readiness is
  /// [Readyness.Stale]), but are no longer kept up to date. Providers report
  /// this as stale.
  bool get environmentStale => _environmentStaleListeners.value;

  final _connectionFailedListeners = BehaviorSubject<bool>.seeded(false);

  /// True once the connection updating the repository has failed for good
  /// (`notify(SSEResultState.failure, ...)`: a rejected API key, a browser
  /// connection error, no reconnection attempts left): it will send nothing
  /// more. Before any features readiness is then [Readyness.Failed];
  /// after them it is [Readyness.Stale] and the features keep being
  /// resolved. Providers report this as stale.
  bool get connectionFailed => _connectionFailedListeners.value;

  /// Emits false, then true if and when the connection fails for good (see
  /// [connectionFailed]). Separate from [readynessStream].
  Stream<bool> get connectionFailedStream => _connectionFailedListeners.stream;

  /// True once the source has stopped for good ([connectionFailed] or
  /// [environmentStale]): nothing will bring the features up to date.
  bool get _stoppedForGood => connectionFailed || environmentStale;

  /// Emits false, then true if and when the environment becomes stale (see
  /// [environmentStale]).
  Stream<bool> get environmentStaleStream => _environmentStaleListeners.stream;

  /// Called by a transport when the source says the environment is stale and
  /// will send no further updates (after giving the last features). The
  /// transport then stops.
  void markEnvironmentStale() {
    if (_environmentStaleListeners.isClosed || environmentStale) return;
    _log.warning(
      'featurehub: this environment has gone stale and will not receive '
      'further updates.',
    );
    _environmentStaleListeners.add(true);
    // the features held are the last there will be; before any features
    // readiness is unchanged
    if (_readynessState == Readyness.Ready) _setReadyness(Readyness.Stale);
  }

  /// A context change is in progress (the providers call this before asking
  /// the transport for the new context's features): readiness goes from
  /// [Readyness.Ready] to [Readyness.Stale], as the features held are for the
  /// old context. They are still resolved. The next full set of features
  /// makes it Ready again. Does nothing unless Ready.
  void contextChanging() {
    if (_readynessState == Readyness.Ready) _setReadyness(Readyness.Stale);
  }

  void _setReadyness(Readyness readyness) {
    _readynessState = readyness;
    _broadcastReadynessState();
  }

  /// Readiness after a full set of features: Ready, unless nothing will bring
  /// them up to date (then Stale); Failed is final.
  void _fullSetReceived() {
    if (_readynessState == Readyness.Failed) return;
    _setReadyness(_stoppedForGood ? Readyness.Stale : Readyness.Ready);
  }

  /// Emits when new feature states are available: when they have been
  /// applied, or in catch and release mode, when they have been caught and are
  /// waiting for [release].
  Stream<ClientFeatureRepository> get newFeatureStateAvailableStream =>
      _newFeatureStateAvailableListeners.stream;

  /// Emits whenever changes to the features have been applied: updates
  /// (including those applied by [release]) and deletions. Unlike
  /// [newFeatureStateAvailableStream], it never emits for updates that are
  /// only caught in catch and release mode.
  Stream<ClientFeatureRepository> get featuresChangedStream =>
      _featuresChangedListeners.stream;

  void _featuresChanged() => _featuresChangedListeners.add(this);

  /// The [computeSha] of the features the repository holds.
  ///
  /// It is computed again whenever features arrive, a feature is updated or
  /// deleted, and when caught features are released, however they arrive
  /// (streaming, polling or a store). In catch and release mode it describes
  /// the features applied, not those held back. It identifies the features
  /// only for client-evaluated API keys, which every client receives alike
  /// (with a server-evaluated key, the features differ by context).
  ///
  /// A transport can send it as an `ETag`, or compare it with a snapshot's
  /// [FeatureSnapshot.sha] to see whether the features have changed.
  String get featuresSha => _featuresSha;

  void _updateFeaturesSha() => _featuresSha = computeSha(featureStates);

  /// The SHA-256 (hex) of [features]' `id:version`s, sorted by id and joined
  /// with `|`, as every FeatureHub SDK computes it (for example for the
  /// Redis store's `_sha` key).
  static String computeSha(Iterable<FeatureState> features) {
    final sorted = [...features]..sort((a, b) => a.id.compareTo(b.id));
    final input = sorted.map((f) => '${f.id}:${f.version}').join('|');
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Every feature change as it arrives, before catch and release handling,
  /// with its source: for stores that keep a copy of the features (see
  /// [FeatureStore]). Events are delivered asynchronously.
  Stream<RawFeatureUpdate> get rawFeatureUpdates => _rawUpdates.stream;

  void _raw(RawFeatureUpdate update) {
    if (!_rawUpdates.isClosed) _rawUpdates.add(update);
  }

  /// [data] as a feature, or null (logged) if it is not a valid one: a
  /// feature needs an id, a key, a version and a type.
  static FeatureState? _featureState(dynamic data) {
    if (data is FeatureState) return data;
    if (data is Map) {
      try {
        return FeatureState.fromJson(Map<String, dynamic>.from(data));
      } catch (e) {
        _log.warning('featurehub: ignoring an invalid feature ($e): $data');
        return null;
      }
    }
    _log.warning('featurehub: ignoring an invalid feature: $data');
    return null;
  }

  /// [data] as a full set of features, or null (logged) if it is not a list.
  /// Entries that are not valid features are left out.
  static List<FeatureState>? _fullSet(dynamic data) {
    if (data is List<FeatureState>) return data;
    if (data is! List) {
      _log.warning(
        'featurehub: ignoring features that are not a list: '
        '${data.runtimeType}',
      );
      return null;
    }
    return [for (final entry in data) ?_featureState(entry)];
  }

  Iterable<String?> get availableFeatures => _features.keys;

  /// used by a provider of features to tell the repository about updates to those features.
  /// If you were storing features on your device you could use this to fill the repository before it was connected for example.
  ///
  /// [source] is where the data came from: FeatureHub by default, or e.g. a
  /// [FeatureStore] loading the features it holds. It is passed on with
  /// [rawFeatureUpdates].
  void notify(
    SSEResultState? state,
    dynamic data, {
    String source = featureHubEdgeSource,
  }) {
    _log.fine('Data from $source is $state -> $data');
    if (state != null) {
      switch (state) {
        case SSEResultState.ack:
          break;
        case SSEResultState.bye:
          // the connection is being re-established: the features held are
          // still the latest known, so readiness is unchanged (still Ready
          // once features have arrived), and nothing is broadcast
          break;
        case SSEResultState.failure:
          // once: later failures change nothing
          if (connectionFailed || _connectionFailedListeners.isClosed) break;
          _initialStateResolved = true;
          _connectionFailedListeners.add(true);
          if (!_hasReceivedInitialState) {
            // before any full set of features: final
            if (_readynessState == Readyness.NotReady) {
              _setReadyness(Readyness.Failed);
            }
          } else if (_readynessState == Readyness.Ready) {
            // the features keep being resolved, but are no longer updated
            _setReadyness(Readyness.Stale);
          }
          break;
        case SSEResultState.features:
          // not a list is not a full set: removing every feature not in it
          // would empty the repository
          final features = _fullSet(data);
          if (features == null) break;
          _raw(FeaturesReceived(List.unmodifiable(features), source));
          if (_hasReceivedInitialState && _catchActive) {
            _catchUpdatedFeatures(features);
            _caughtFullSetKeys = {for (final f in features) f.key};
            // the features are held back, but they have arrived, so the
            // repository is ready (unless the source has stopped for good)
            final before = _readynessState;
            if (before == Readyness.NotReady || before == Readyness.Stale) {
              _fullSetReceived();
            }
          } else {
            var updated = false;
            for (var f in features) {
              updated = _featureUpdate(f) || updated;
            }
            // a full set: features missing from it no longer exist
            updated =
                _removeMissing({for (final f in features) f.key}) || updated;
            if (updated) _featuresChanged();
            if (!_hasReceivedInitialState) {
              _checkForInvalidFeatures();
              _hasReceivedInitialState = true;
            } else if (updated) {
              _triggerNewStateAvailable();
            }
            if (source == featureHubEdgeSource) _initialStateResolved = true;
            _updateFeaturesSha();
            _fullSetReceived();
          }
          break;
        case SSEResultState.feature:
          final feature = _featureState(data);
          if (feature == null) break;
          _raw(FeatureReceived(feature, source));
          if (_catchActive) {
            _catchUpdatedFeatures([feature]);
            _caughtFullSetKeys?.add(feature.key);
          } else {
            if (_featureUpdate(feature)) {
              _updateFeaturesSha();
              _featuresChanged();
              _triggerNewStateAvailable();
            }
          }
          break;
        case SSEResultState.deleteFeature:
          // only the key (and id) are needed
          final feature = _deletedFeature(data);
          if (feature == null) break;
          // an update held back for it must not bring it back on release
          _catchReleaseStates.removeWhere(
            (id, f) => id == feature.id || f.key == feature.key,
          );
          _caughtFullSetKeys?.remove(feature.key);
          _deleteFeature(feature);
          _raw(FeatureDeleted(feature.key, feature.id, source));
          break;
        case SSEResultState.config:
        case SSEResultState.error:
          // not repository state: config is handled by the transport layer
          break;
      }
    }
  }

  /// The feature [data] (a [FeatureState] or its JSON) deletes: only its
  /// key, and id if given, are needed.
  static ({String key, String? id})? _deletedFeature(dynamic data) {
    if (data is FeatureState) return (key: data.key, id: data.id);
    if (data is Map && data['key'] is String) {
      final id = data['id'];
      return (key: data['key'] as String, id: id is String ? id : null);
    }
    _log.warning('featurehub: ignoring an invalid feature deletion: $data');
    return null;
  }

  void _broadcastReadynessState() {
    if (!_readynessListeners.isClosed) {
      _readynessListeners.add(_readynessState);
    }
  }

  void _catchUpdatedFeatures(List<FeatureState> features) {
    var updatedValues = false;
    for (var f in features) {
      final fs = _catchReleaseStates[f.id];
      if (fs == null) {
        _catchReleaseStates[f.id] = f;
        updatedValues = true;
      } else {
        if (f.version > fs.version) {
          _catchReleaseStates[f.id] = f;
          updatedValues = true;
        }
      }
    }

    if (updatedValues) {
      _triggerNewStateAvailable();
    }
  }

  void _checkForInvalidFeatures() {
    final missingKeys = _features.keys
        .where((k) => _features[k]!.key == null)
        .toList()
        .join(',');
    if (missingKeys.isNotEmpty) {
      _log.info('We have requests for keys that are missing: $missingKeys');
    }
  }

  void _triggerNewStateAvailable() {
    if (_hasReceivedInitialState) {
      if (!_catchActive || _catchReleaseStates.isNotEmpty) {
        _newFeatureStateAvailableListeners.add(this);
      }
    }
  }

  /// Evaluates feature [key] for [context].
  ///
  /// If the feature has rollout strategies (they are only sent for
  /// client-evaluated API keys) they are applied to [context]; otherwise the
  /// feature's value is returned as is. A registered value interceptor that
  /// matches takes precedence (unless the feature is locked and the
  /// interceptor may not override locks).
  EvaluatedFeature evaluate(String key, {StrategyContext? context}) {
    final fs = _features[key]?._featureState;

    final locked = fs?.l == true;
    for (final vi in _featureValueInterceptors) {
      if (locked && !vi.allowLockOverride) continue;
      final vm = vi.match(key, fs);
      if (vm.matched) {
        return EvaluatedFeature(
          key: key,
          featureState: fs,
          value: vm.value,
          intercepted: true,
        );
      }
    }

    if (fs == null) {
      return EvaluatedFeature(key: key);
    }

    final strategies = fs.strategies;
    if (strategies == null || strategies.isEmpty) {
      // server-evaluated (or no strategies): the server has already applied
      // any matching strategy and reports its id in `v`
      return EvaluatedFeature(
        key: key,
        featureState: fs,
        value: fs.value,
        strategyId: fs.v,
      );
    }

    // client-evaluated: apply the strategies to the context ourselves
    final applied = applyFeature.apply(strategies, key, fs.id, context);
    return EvaluatedFeature(
      key: key,
      featureState: fs,
      value: applied.matched ? applied.value : fs.value,
      strategyId: applied.matched ? applied.strategyId : null,
      split: applied.matched && applied.split,
    );
  }

  /// The features the repository holds, with their [featuresSha], for a
  /// server to pass on to its own clients (which load them with
  /// [loadFeatureSnapshot]).
  ///
  /// With a [context] (an OpenFeature evaluation context, in map form, see
  /// [mapEvaluationContext]), each feature's strategies are applied to it, as
  /// FeatureHub does for a server-evaluated API key: the features have the
  /// value for that context, no strategies, and `v` the id of the strategy
  /// that matched (null if none did). Features without strategies are as
  /// delivered.
  ///
  /// With no context (null or empty), the caller decides with
  /// [includeStrategies]:
  ///
  /// - false (the default): the features are evaluated as for an empty
  ///   context, so no strategy is exposed.
  /// - true: the features are as delivered by FeatureHub (copies, rollout
  ///   strategies included), for clients that evaluate them locally. That
  ///   exposes every strategy and its values, so only do it for trusted
  ///   clients.
  ///
  /// Value interceptors are not applied: they override values locally, so
  /// they are not passed on.
  ///
  /// Throws an [InvalidContextException] if [context] holds a value
  /// FeatureHub cannot represent.
  FeatureSnapshot featureSnapshot({
    Map<String, Object?>? context,
    bool includeStrategies = false,
  }) {
    final noContext = context == null || context.isEmpty;
    final strategyContext = noContext && includeStrategies
        ? null
        : mapEvaluationContext(context ?? const {}).strategyContext;
    final features = [
      for (final fs in featureStates)
        strategyContext == null
            ? fs.copyWith()
            : _evaluatedFor(fs, strategyContext),
    ];
    return FeatureSnapshot(_featuresSha, features);
  }

  /// Loads the features in [data] as a full set (features not in it are
  /// removed), as if FeatureHub had sent them: for a transport of your own,
  /// for example one fetching the features from your own server's API, which
  /// returns [featureSnapshot].
  ///
  /// [data] is a [FeatureSnapshot], its JSON form (a map or a JSON string),
  /// or a list of features (as [FeatureState]s or their JSON). Returns the
  /// snapshot loaded. Throws a [FormatException] if [data] is none of these,
  /// leaving the repository unchanged.
  FeatureSnapshot loadFeatureSnapshot(dynamic data) {
    final snapshot = FeatureSnapshot.from(data);
    notify(SSEResultState.features, snapshot.features);
    return snapshot;
  }

  FeatureState _evaluatedFor(FeatureState fs, StrategyContext context) {
    final strategies = fs.strategies;
    if (strategies == null || strategies.isEmpty) return fs.copyWith();
    final applied = applyFeature.apply(strategies, fs.key, fs.id, context);
    return FeatureState(
      id: fs.id,
      key: fs.key,
      l: fs.l,
      version: fs.version,
      type: fs.type,
      value: applied.matched ? applied.value : fs.value,
      v: applied.matched ? applied.strategyId : null,
      fp: fs.fp == null ? null : Map.of(fs.fp!),
      environmentId: fs.environmentId,
    );
  }

  /// The features currently known (excluding keys that have only been asked
  /// for), as delivered by the server.
  Iterable<FeatureState> get featureStates =>
      _features.values.map((h) => h._featureState).whereType<FeatureState>();

  /// returns [FeatureStateHolder] if feature key exists or [null] if the feature value is not set or does not exist
  FeatureStateHolder getFeatureState(String? key) {
    return _features.putIfAbsent(
      key,
      () => _FeatureStateBaseHolder(null, this),
    );
  }

  ///returns [FeatureStateHolder] if feature key exists or [null] if the feature value is not set or does not exist
  FeatureStateHolder feature(String? key) {
    return getFeatureState(key);
  }

  /// @param key The feature key
  /// @returns A boolean (flag) feature value or [null] if the feature does not exist.
  bool? getFlag(String key) {
    return feature(key).booleanValue;
  }

  /// @param key The feature key
  /// @returns The value of the number feature or [null]
  /// if the feature value not set or does not exist
  num? getNumber(String key) {
    return feature(key).numberValue;
  }

  /// @param key The feature key
  /// @returns The value of the string feature or [null]
  /// if the feature value not set or does not exist
  String? getString(String key) {
    return feature(key).stringValue;
  }

  /// @param key The feature key
  /// @returns The value of the json feature or [null]
  /// if the feature value not set or does not exist
  dynamic getJson(String key) {
    return feature(key).jsonValue;
  }

  bool isSet(String key) {
    return feature(key).isSet;
  }

  bool isEnabled(String key) {
    return feature(key).isEnabled;
  }

  /// @param key The feature key
  /// returns true if the feature key exists, otherwise false
  bool exists(String key) {
    return feature(key).exists;
  }

  /// In catch and release mode, feature updates are held back (and announced
  /// on [newFeatureStateAvailableStream]) until [release] is called.
  ///
  /// The mode takes effect only once the first set of features (or a failure)
  /// has arrived, so it can be switched on as soon as the repository is
  /// created: the initial features are applied, and the initial readiness is
  /// broadcast, as normal.
  bool get catchAndReleaseMode => _catchAndReleaseMode;
  set catchAndReleaseMode(bool val) {
    if (_catchAndReleaseMode && !val) {
      release(disableCatchAndRelease: true);
    } else {
      _catchAndReleaseMode = val;
    }
  }

  Readyness get readyness => _readynessState;

  Future<void> release({bool disableCatchAndRelease = false}) async {
    var updated = false;
    final fullSetKeys = _caughtFullSetKeys;
    _caughtFullSetKeys = null;
    while (_catchReleaseStates.isNotEmpty) {
      final states = <FeatureState>[..._catchReleaseStates.values];
      _catchReleaseStates.clear();
      for (var f in states) {
        updated = _featureUpdate(f) || updated;
      }
    }
    if (fullSetKeys != null) {
      updated = _removeMissing(fullSetKeys) || updated;
    }
    if (updated) {
      _updateFeaturesSha();
      _featuresChanged();
    }

    if (disableCatchAndRelease == true) {
      _catchAndReleaseMode = false;
    }
  }

  bool _featureUpdate(FeatureState feature) {
    var holder = _features[feature.key];

    if (holder == null || holder.key == null) {
      holder = _FeatureStateBaseHolder(holder, this);
    } else {
      if (holder.version != null) {
        // a server-evaluated feature can change value, or matched strategy,
        // without changing version when the context changes; and a feature
        // from a store (e.g. a local file) may differ from FeatureHub's in id
        // or type at the same version
        final current = holder._featureState;
        if (holder.version! > feature.version ||
            (holder.version == feature.version &&
                holder._value == feature.value &&
                current?.v == feature.v &&
                current?.id == feature.id &&
                current?.type == feature.type)) {
          return false;
        }
      }
    }

    holder.featureState = feature;
    _features[feature.key] = holder;

    return true;
  }

  /// register an interceptor, indicating whether it is allowed to override
  /// the locking coming from the server
  void registerFeatureValueInterceptor(
    bool allowLockOverride,
    FeatureValueInterceptor fvi,
  ) {
    _featureValueInterceptors.add(
      _InterceptorHolder(allowLockOverride, (key, _) => fvi(key)),
    );
  }

  /// Adds [interceptor], which then supplies the values of the features it
  /// matches. Unless [allowLockOverride] is false it also overrides locked
  /// features (as the other FeatureHub SDKs' interceptors do). It is closed
  /// when the repository shuts down.
  void addValueInterceptor(
    ValueInterceptor interceptor, {
    bool allowLockOverride = true,
  }) {
    _featureValueInterceptors.add(
      _InterceptorHolder(allowLockOverride, interceptor.matched, interceptor),
    );
  }

  /// Removes [interceptor] (without closing it).
  void removeValueInterceptor(ValueInterceptor interceptor) {
    _featureValueInterceptors.removeWhere(
      (h) => identical(h.interceptor, interceptor),
    );
  }

  /// Removes the features whose keys are not in [keys] (keys only asked
  /// for, which have no feature yet, are kept). Returns true if any were.
  bool _removeMissing(Set<String> keys) {
    final missing = [
      for (final MapEntry(:key, :value) in _features.entries)
        if (value._featureState != null && !keys.contains(key)) key,
    ];
    for (final key in missing) {
      _features.remove(key);
    }
    return missing.isNotEmpty;
  }

  void _deleteFeature(({String key, String? id}) feature) {
    if (_features.remove(feature.key) != null) {
      _updateFeaturesSha();
      _featuresChanged();
    }
  }

  /// call this to clear the repository if you are swapping environments.
  /// With no features left, readiness becomes [Readyness.NotReady]: from
  /// Ready it goes to Stale first (both are broadcast).
  void shutdownFeatures() {
    for (var f in _features.values) {
      f.shutdown();
    }
    _features.clear();
    _updateFeaturesSha();
    if (_readynessState == Readyness.Ready) _setReadyness(Readyness.Stale);
    if (_readynessState == Readyness.Stale) _setReadyness(Readyness.NotReady);
  }

  /// after this method is called, the repository is not usable, create a new one.
  void shutdown() {
    _readynessListeners.close();
    _environmentStaleListeners.close();
    _connectionFailedListeners.close();
    _newFeatureStateAvailableListeners.close();
    _featuresChangedListeners.close();
    _rawUpdates.close();
    for (final h in _featureValueInterceptors) {
      h.interceptor?.close();
    }
    _featureValueInterceptors.clear();
    shutdownFeatures();
  }
}
