import 'dart:async';

import 'package:featurehub_analytics_api/analytics.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal_repository.dart';

import 'internal_features.dart';
import 'log.dart';

class ServerEvalClientContext extends InternalContext {
  final EdgeService edgeService;
  late StreamSubscription<FeatureRepository> featureUpdateStream;
  late StreamSubscription<FeatureStateBaseHolder> featureListener;

  ServerEvalClientContext(InternalFeatureRepository repo, this.edgeService) : super(repo) {
    featureUpdateStream = repo.newFeatureStateAvailableStream.listen((event) {
      recordRelativeValuesForUser();
    });

    featureListener = repo.featureUpdatedStream.listen((feature) {
      recordFeatureChangedForUser(feature);
    });
  }

  String? generateHeader() {
    log.finest(("ServerContext - generating header ${attributes}"));
    if (attributes.isEmpty) {
      return null;
    }

    var params = attributes.entries.map((entry) {
      return entry.key + '=' + Uri.encodeQueryComponent(entry.value.join(','));
    }).toList();
    params.sort(); // i so hate the sort function
    return params.join(',');
  }

  @override
  Future<ClientContext> build() async {
    await edgeService.contextChange(generateHeader() ?? '');

    // we may not get any new state but the context changed, so we need to update it
    recordRelativeValuesForUser();

    return this;
  }

  @override
  FeatureStateHolder feature(String key) => repo.feat(key).withContext(this);

  @override
  void recordAnalyticsEvent(AnalyticsEvent analyticsEvent) {
    super.recordAnalyticsEvent(analyticsEvent);

    repo.recordAnalyticsEvent(analyticsEvent);
  }

  @override
  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType) async {
    await repo.used(key, id, val, valueType, attributes, analyticsUserKey());
    await edgeService.poll();
  }

  void close() {
    featureUpdateStream.cancel();
    featureListener.cancel();
  }
}