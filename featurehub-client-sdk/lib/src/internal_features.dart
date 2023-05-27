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

  String get id => _topFeatureStateHolder()._featureState?.id ?? '';

  @override
  String get key => _topFeatureStateHolder()._featureState?.key ?? _key;

  @override
  dynamic get value => _getValue(type);

  /// this is used by the repository to get the raw value
  dynamic get rawValue => _topFeatureStateHolder()._featureState?.value;

  bool get set => exists && _getValue(type) != null;

  bool get enabled => _getValue(FeatureValueType.BOOLEAN) == true;

  /// this always happens at a top level feature
  set featureState(FeatureState? fs) {
    final oldValue = _featureState?.value;
    _featureState = fs;
    if (fs?.value != oldValue) {
      _listeners!.add(this);
    }
  }

  @override
  int get version =>  _topFeatureStateHolder()._featureState?.version ?? -1;

  void delete() => _topFeatureStateHolder()._featureState?.version = -1;

  @override
  bool get exists => (_topFeatureStateHolder()._featureState?.version ?? -1) != -1;

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
  FeatureValueType? get type => _topFeatureStateHolder()._featureState?.type;

  @override
  FeatureStateHolder copy() {
    return FeatureStateBaseHolder(this.key, this.repo, featureState: _topFeatureStateHolder()._featureState?.copyWith(), ctx: this.clientContext);
  }

  FeatureStateHolder withContext(InternalContext ctx) {
    return FeatureStateBaseHolder(this.key, this.repo, parentState: this, ctx: ctx);
  }

  void shutdown() {
    _listeners!.close();
  }

  bool get locked => _topFeatureStateHolder()._featureState?.l == true;

  FeatureStateBaseHolder _topFeatureStateHolder() {
    if (_parentState != null) {
      return _parentState!._topFeatureStateHolder();
    }

    return this;
  }

  /// this simply gets the value of this feature without triggering any analytics, it
  /// is required in the contexts because they gather the values of the features
  dynamic get analyticsFreeValue => _getValue(type, triggerUsed: false);

  dynamic _getValue(FeatureValueType? type, {bool triggerUsed = true}) {
    if (type == null) {
      return null;
    }

    final top = _topFeatureStateHolder();
    final topKey = top.key;

    final interceptor = repo.findInterceptor(topKey, top._featureState?.l ?? false);
    if (interceptor != null && interceptor.matched) {
      return triggerUsed ? _used(top._key, top._featureState?.id ?? top._key, interceptor.val, top._featureState?.type ?? interceptor.inferType) : interceptor.val;
    }

    if (top._featureState == null) {
      return null;
    }

    final state = top._featureState!;

    if (state.type != type) {
      return null;
    }

    if (clientContext != null && state.strategies.isNotEmpty) {
      final matched = repo.apply(state.strategies, topKey, state.id, clientContext);
      if (matched.matched) {
        return triggerUsed ? _used(topKey, state.id, matched.value, type) : matched.value;
      }
    }

    return triggerUsed ? _used(state.key, state.id, state.value, type) : state.value;
  }

  dynamic _used(String featureKey, String featureId, dynamic val, FeatureValueType type) {
    print("used, ${clientContext != null}");
    if (clientContext != null) {
      clientContext!.used(featureKey, featureId, val, type);
    }

    return val;
  }

  @override
  String get rawJson => _getValue(FeatureValueType.JSON) as String;
}