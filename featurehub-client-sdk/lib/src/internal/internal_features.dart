import 'dart:async';
import 'dart:convert';

import 'package:featurehub_client_api/api.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

import '../features.dart';
import 'internal_context.dart';
import 'internal_repository.dart';



@internal
class FeatureStateBaseHolder implements FeatureStateHolder {
  dynamic _value;
  FeatureState? _featureState;
  BehaviorSubject<FeatureStateHolder>? _listeners;
  InternalFeatureRepository repo;
  FeatureStateBaseHolder? _parentState;
  InternalContext? clientContext;
  final String _key;

  @override
  Stream<FeatureStateHolder> get featureUpdateStream => _listeners!.stream;

  FeatureStateBaseHolder(this._key, this.repo,
  {FeatureState? featureState = null, FeatureStateBaseHolder? parentState = null, InternalContext? ctx = null}) {

    this._featureState = featureState;
    this._parentState = parentState;
    this.clientContext = ctx;

    // always share the parent's listeners if we can
    _listeners = parentState?._listeners ?? BehaviorSubject<FeatureStateHolder>();
  }

  @override
  String get key => _topFeatureState()._featureState?.key ?? _key;

  @override
  dynamic get value => _value;

  bool get set => _value != null;

  bool get enabled => _featureState?.type == FeatureValueType.BOOLEAN && _value == true;

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
  bool get hasValue => exists && _getValue(type) != null;

  @override
  bool get exists => _topFeatureState()._featureState?.version != -1;

  @override
  bool? get flag => _getValue(FeatureValueType.BOOLEAN) as bool?;

  @override
  String? get string => _getValue(FeatureValueType.STRING) as String?;

  @override
  num? get number => _getValue(FeatureValueType.NUMBER) as num?;

  @override
  dynamic get json {
    String? body = _getValue(FeatureValueType.JSON);

    return body == null ? null : jsonDecode(body);
  }

  @override
  FeatureValueType? get type => _featureState!.type;

  @override
  FeatureStateHolder copy() {
    return FeatureStateBaseHolder(this.key, this.repo, featureState: this._featureState, parentState: this, ctx: this.clientContext);
  }

  FeatureStateHolder withContext(InternalContext ctx) {
    return FeatureStateBaseHolder(this.key, this.repo, featureState: this._featureState, parentState: this, ctx: ctx);
  }

  void shutdown() {
    _listeners!.close();
  }

  bool get locked {
    if (exists) {
      return _featureState?.l == true;
    }

    return false;
  }

  FeatureStateBaseHolder _topFeatureState() {
    if (_parentState != null) {
      return _parentState!._topFeatureState();
    }

    return this;
  }

  dynamic _getValue(FeatureValueType? type) {
    if (type == null) {
      return null;
    }

    if (!locked) {
      // do interceptors
    }

    final top = _topFeatureState();
    if (top._featureState == null) {
      return null;
    }

    final state = top._featureState!;

    if (state.type != type) {
      return null;
    }

    if (clientContext != null && state.strategies.isNotEmpty) {
      final matched = repo.apply(state.strategies, key, state.id, clientContext);
      if (matched.matched) {
        return _used(state.key, state.id, InterceptorValue(true, matched.value).cast(type), type);
      }
    }

    return _used(state.key, state.id, state.value, type);
  }

  dynamic _used(String featureKey, String featureId, dynamic val, FeatureValueType type) {
    if (clientContext != null) {
      clientContext!.used(featureKey, featureId, val, type);
    }

    return val;
  }
}
