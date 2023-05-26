import 'dart:async';

import 'package:featurehub_analytics_api/analytics.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

import 'internal_context.dart';
import 'internal_features.dart';
import 'internal_repository.dart';

class _InterceptorHolder {
  final bool allowLockOverride;
  final FeatureValueInterceptor interceptor;

  _InterceptorHolder(this.allowLockOverride, this.interceptor);
}

@internal
class ClientFeatureRepository extends InternalFeatureRepository {
  bool _hasReceivedInitialState = false;

  // indexed by key
  final Map<String, FeatureStateBaseHolder> _features = {};
  final Map<String, FeatureStateBaseHolder> _featuresById = {};
  Readiness _readiness = Readiness.NotReady;
  final _readinessListeners =
  BehaviorSubject<Readiness>.seeded(Readiness.NotReady);
  final _analyticsSource = BehaviorSubject<AnalyticsEvent>();
  final _newFeatureStateAvailableListeners = PublishSubject<FeatureRepository>();
  bool _catchAndReleaseMode = false;
  AnalyticsProvider analyticsProvider = AnalyticsProvider();

  // indexed by id (not key)
  final Map<String?, FeatureState> _catchReleaseStates = {};
  final List<_InterceptorHolder> _featureValueInterceptors = [];

  Stream<AnalyticsEvent> get analyticsStream => _analyticsSource.stream;

  Stream<Readiness> get readinessStream => _readinessListeners.stream;

  Stream<FeatureRepository> get newFeatureStateAvailableStream =>
      _newFeatureStateAvailableListeners.stream;

  Iterable<String> get availableFeatures => _features.keys;

  /// used by a provider of features to tell the repository about updates to those features.
  /// If you were storing features on your device you could use this to fill the repository before it was connected for example.
  void notify(SSEResultState? state) {
    if (state != null) {
      switch (state) {
        case SSEResultState.failure:
          _readiness = Readiness.Failed;
          if (!_catchAndReleaseMode) {
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.bye: // this is only temporary but needs to be notified in case it becomes permanent for a health check
          _readiness = Readiness.NotReady;
          if (!_catchAndReleaseMode) {
            _broadcastReadynessState();
          }
          break;
        case SSEResultState.ack:
        case SSEResultState.features:
        case SSEResultState.feature:
        case SSEResultState.deleteFeature:
        case SSEResultState.config:
        case SSEResultState.error:
          break;
      }
    }
  }

  void _broadcastReadynessState() {
    if (!_readinessListeners.hasValue || _readinessListeners.value != _readiness ) {
      _readinessListeners.add(_readiness);
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
        if (fs.version == null || f.version! > fs.version!) {
          _catchReleaseStates[f.id] = f;
          updatedValues = true;
        }
      }
    }

    if (updatedValues) {
      _triggerNewStateAvailable();
    }
  }

  void _triggerNewStateAvailable() {
    if (_hasReceivedInitialState) {
      if (!_catchAndReleaseMode || _catchReleaseStates.isNotEmpty) {
        _newFeatureStateAvailableListeners.add(this);
      }
    }
  }


  ///returns [FeatureStateHolder] if feature key exists or [null] if the feature value is not set or does not exist
  FeatureStateHolder feature(String key) {
    return feat(key);
  }

  bool get catchAndReleaseMode => _catchAndReleaseMode;

  set catchAndReleaseMode(bool val) {
    if (_catchAndReleaseMode && !val) {
      release(disableCatchAndRelease: true);
    } else {
      _catchAndReleaseMode = val;
    }
  }

  Future<void> release({bool disableCatchAndRelease = false}) async {
    while (_catchReleaseStates.isNotEmpty) {
      final states = <FeatureState>[..._catchReleaseStates.values];
      _catchReleaseStates.clear();
      states.forEach((f) => _featureUpdate(f));
    }

    if (disableCatchAndRelease == true) {
      _catchAndReleaseMode = false;
    }
  }

  /// register an interceptor, indicating whether it is allowed to override
  /// the locking coming from the server
  void registerFeatureValueInterceptor(bool allowLockOverride,
      FeatureValueInterceptor fvi) {
    _featureValueInterceptors.add(_InterceptorHolder(allowLockOverride, fvi));
  }

  /// call this to clear the repository if you are swapping environments
  void shutdownFeatures() {
    _features.values.forEach((f) => f.shutdown());
    _features.clear();
  }

  /// after this method is called, the repository is not usable, create a new one.
  void shutdown() {
    _readinessListeners.close();
    _newFeatureStateAvailableListeners.close();
    shutdownFeatures();
  }

  @override
  AppliedValue apply(List<FeatureRolloutStrategy> strategies, String key,
      String id, InternalContext? clientContext) {
    // TODO: implement apply
    throw UnimplementedError();
  }

  @override
  void deleteFeature(FeatureState feature) {
    // just set the version to -1
    if (_featuresById.containsKey(feature.id)) {
      updateFeature(feature..version = -1);
    }
  }

  @override
  FeatureStateBaseHolder feat(String key) {
    return _features.putIfAbsent(
        key, () => FeatureStateBaseHolder(key, this));
  }

  @override
  InterceptorValue? findInterceptor(String key, bool locked) {
    for (var value in _featureValueInterceptors) {
      if (!locked || (value.allowLockOverride && locked)) {
        final val = value.interceptor.matches(key);
        if (val.matched) {
          return val;
        }
      }
    }

    return null;
  }

  @override
  Readiness get readiness => _readiness;

  @override
  repositoryEmpty() {
    _features.clear();
    _readiness = Readiness.NotReady;
    _broadcastReadynessState();
  }

  @override
  repositoryNotReady() {
    _readiness = Readiness.NotReady;
    _broadcastReadynessState();
  }

  bool _featureUpdate(FeatureState feature) {
    var holder = _features[feature.key];

    if (holder == null) {
      holder = FeatureStateBaseHolder(feature.key, this);
    } else {
      if (feature.version != -1) { // delete takes precedence with -1
        if (holder.version > feature.version! ||
            (holder.version == feature.version &&
                holder.value == feature.value)) {
          return false;
        }
      }
    }

    holder.featureState = feature;
    _features[feature.key] = holder;
    _featuresById[feature.id] = holder;

    return true;
  }

  @override
  void updateFeature(FeatureState feature) {
    if (_catchAndReleaseMode) {
      _catchUpdatedFeatures([feature]);
    } else {
      if (_featureUpdate(feature)) {
        _triggerNewStateAvailable();
      }
    }
  }

  @override
  void updateFeatures(List<FeatureState> features) {
    if (_hasReceivedInitialState && _catchAndReleaseMode) {
      _catchUpdatedFeatures(features);
    } else {
      var _updated = false;

      final Map<String,FeatureState> newFeaturesById = Map.fromIterable(features, key: (f) => f.id, value: (f) => f);

      features.forEach((f) => _updated = _featureUpdate(f) || _updated);

      _removeDeletedFeatures(newFeaturesById);

      if (!_hasReceivedInitialState) {
        _hasReceivedInitialState = true;
      } else if (_updated) {
        _triggerNewStateAvailable();
      }

      _readiness = Readiness.Ready;
      _broadcastReadynessState();
    }
  }

  void _removeDeletedFeatures(Map<String, FeatureState> newFeaturesById) {
    final toDeleteHolders = <FeatureStateBaseHolder>[];
    final toDeleteIds = <String>[];
    _featuresById.values.forEach((f) {
      var id = f.id;
      if (!newFeaturesById.containsKey(id)) {
        toDeleteHolders.add(f);
        toDeleteIds.add(id);
      }
    });

    toDeleteIds.forEach((id) => _featuresById.remove(id) );
    // we do this directly as the implication is that it has already gone through the catchAndRelease mechanism.
    toDeleteHolders.forEach((f) => f.delete());
  }

  @override
  Set<String> get features => _features.keys.toSet();

  @override
  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType, Map<String, List<String>> attributes, String? analyticsUserKey) async {
    _analyticsSource.add(analyticsProvider.createAnalyticsFeatureEvent(FeatureHubAnalyticsValue.byValue(id, key, val, valueType), attributes, analyticsUserKey));
  }

  @override
  void recordAnalyticsEvent(AnalyticsFeaturesCollection event) {
    if (event.featureValues.isEmpty) {
      // these ones are context-less
      final featureStateAtCurrentTime =
      _features.values.map((e) => FeatureHubAnalyticsValue(e)).toList();

      event.featureValues = featureStateAtCurrentTime;
      event.ready();
    }

    _analyticsSource.add(event);
  }

  @override
  void registerAnalyticsProvider(AnalyticsProvider provider) {
    analyticsProvider = provider;
  }
}
