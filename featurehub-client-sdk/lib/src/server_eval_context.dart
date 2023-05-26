

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_sdk/src/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal_repository.dart';

import 'log.dart';

class ServerEvalClientContext extends InternalContext {
  final EdgeService edgeService;

  ServerEvalClientContext(InternalFeatureRepository repo, this.edgeService) : super(repo);

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

    repo.recordAnalyticsEvent(
        repo.analyticsProvider.createAnalyticsCollectionEvent()
          ..attributes = attributes
          ..userKey=analyticsUserKey());

    return this;
  }

  @override
  void recordAnalyticsEvent(AnalyticsCollectionEvent analyticsEvent) {
    super.recordAnalyticsEvent(analyticsEvent);

    repo.recordAnalyticsEvent(analyticsEvent);
  }

  @override
  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType) async {
    await repo.used(key, id, val, valueType, attributes, analyticsUserKey());
    await edgeService.poll();
  }

}