import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub.dart';
import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';

// public API; kept as-is rather than renamed to lowerCamelCase
// ignore: constant_identifier_names
enum Readyness { NotReady, Ready, Failed }

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

class ValueMatch {
  final bool matched;
  final String? value;

  ValueMatch(this.matched, this.value);
}

class _InterceptorHolder {
  final bool allowLockOverride;
  final FeatureValueInterceptor interceptor;

  _InterceptorHolder(this.allowLockOverride, this.interceptor);
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

  @override
  bool? get booleanValue =>
      _findIntercept(
            () => _featureState?.type == FeatureValueType.BOOLEAN
                ? _current
                : null,
          )
          as bool?;

  @override
  String? get stringValue =>
      _findIntercept(
            () =>
                (_featureState?.type == FeatureValueType.STRING ||
                    _featureState?.type == FeatureValueType.JSON)
                ? _current
                : null,
          )
          as String?;

  @override
  num? get numberValue =>
      _findIntercept(
            () => _featureState?.type == FeatureValueType.NUMBER
                ? _current
                : null,
          )
          as num?;

  @override
  dynamic get jsonValue {
    String? body = _findIntercept(
      () => _featureState?.type == FeatureValueType.JSON ? _current : null,
    );

    return body == null ? null : jsonDecode(body);
  }

  @override
  FeatureValueType? get type => _featureState!.type;

  @override
  FeatureStateHolder copy() {
    return _FeatureStateBaseHolder(null, _repo)..featureState = _featureState!;
  }

  dynamic _findIntercept(Function determineDefault) {
    final locked = _featureState != null && true == _featureState!.l;

    final found = featureValueInterceptors
        .where((vi) => !locked || vi.allowLockOverride)
        .map((vi) {
          final vm = vi.interceptor(key);
          return vm.matched ? vm : null;
        })
        .where((vm) => vm != null);

    return found.isNotEmpty ? found.first : determineDefault();
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

  /// True once the first set of features, or a failure, has arrived. Catch
  /// and release mode only takes effect after that, so it can be switched on
  /// before connecting without holding back the initial features or hiding
  /// the initial readiness.
  bool _initialStateResolved = false;

  bool get _catchActive => _catchAndReleaseMode && _initialStateResolved;
  // indexed by id (not key)
  final Map<String?, FeatureState> _catchReleaseStates = {};
  final List<_InterceptorHolder> _featureValueInterceptors = [];
  final ClientContext clientContext = ClientContext();

  /// Evaluates rollout strategies for client-evaluated API keys.
  final ApplyFeature applyFeature;

  ClientFeatureRepository({this.applyFeature = const ApplyFeature()});

  Stream<Readyness> get readynessStream => _readynessListeners.stream;

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

  /// Every feature change as it arrives, before catch and release handling,
  /// with its source: for stores that keep a copy of the features (see
  /// [FeatureStore]). Events are delivered asynchronously.
  Stream<RawFeatureUpdate> get rawFeatureUpdates => _rawUpdates.stream;

  void _raw(RawFeatureUpdate update) {
    if (!_rawUpdates.isClosed) _rawUpdates.add(update);
  }

  static FeatureState _featureState(dynamic data) =>
      data is FeatureState ? data : FeatureState.fromJson(data);

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
          _readynessState = Readyness.NotReady;
          if (!_catchActive) {
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.failure:
          _readynessState = Readyness.Failed;
          // an initial failure is always broadcast
          final catching = _catchActive;
          _initialStateResolved = true;
          if (!catching) {
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.features:
          final features = (data is List<FeatureState>)
              ? data
              : FeatureState.listFromJson(data);
          _raw(FeaturesReceived(List.unmodifiable(features), source));
          if (_hasReceivedInitialState && _catchActive) {
            _catchUpdatedFeatures(features);
            // the features are held back, but the connection is back, so
            // (after a bye) the repository is ready again
            if (_readynessState != Readyness.Ready) {
              _readynessState = Readyness.Ready;
              _broadcastReadynessState();
            }
          } else {
            var updated = false;
            for (var f in features) {
              updated = _featureUpdate(f) || updated;
            }
            if (updated) _featuresChanged();
            if (!_hasReceivedInitialState) {
              _checkForInvalidFeatures();
              _hasReceivedInitialState = true;
              _initialStateResolved = true;
            } else if (updated) {
              _triggerNewStateAvailable();
            }
            _readynessState = Readyness.Ready;
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.feature:
          final feature = _featureState(data);
          _raw(FeatureReceived(feature, source));
          if (_catchActive) {
            _catchUpdatedFeatures([feature]);
          } else {
            if (_featureUpdate(feature)) {
              _featuresChanged();
              _triggerNewStateAvailable();
            }
          }
          break;
        case SSEResultState.deleteFeature:
          final feature = _featureState(data);
          _deleteFeature(feature);
          _raw(FeatureDeleted(feature, source));
          break;
        case SSEResultState.config:
        case SSEResultState.error:
          // not repository state: config is handled by the transport layer
          break;
      }
    }
  }

  void _broadcastReadynessState() {
    _readynessListeners.add(_readynessState);
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
      final vm = vi.interceptor(key);
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
    while (_catchReleaseStates.isNotEmpty) {
      final states = <FeatureState>[..._catchReleaseStates.values];
      _catchReleaseStates.clear();
      for (var f in states) {
        updated = _featureUpdate(f) || updated;
      }
    }
    if (updated) _featuresChanged();

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
        // without changing version when the context changes
        if (holder.version! > feature.version ||
            (holder.version == feature.version &&
                holder._value == feature.value &&
                holder._featureState?.v == feature.v)) {
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
    _featureValueInterceptors.add(_InterceptorHolder(allowLockOverride, fvi));
  }

  void _deleteFeature(FeatureState feature) {
    if (_features.remove(feature.key) != null) _featuresChanged();
  }

  /// call this to clear the repository if you are swapping environments
  void shutdownFeatures() {
    for (var f in _features.values) {
      f.shutdown();
    }
    _features.clear();
  }

  /// after this method is called, the repository is not usable, create a new one.
  void shutdown() {
    _readynessListeners.close();
    _newFeatureStateAvailableListeners.close();
    _featuresChangedListeners.close();
    _rawUpdates.close();
    shutdownFeatures();
  }
}
