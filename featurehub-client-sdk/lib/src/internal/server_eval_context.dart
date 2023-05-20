

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/src/internal/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';

import '../config.dart';

class ServerEvalClientContext extends InternalContext {
  final EdgeService edgeService;

  ServerEvalClientContext(InternalFeatureRepository repo, this.edgeService) : super(repo);

  String? generateHeader() {
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
  Future<void> build() async {
    await edgeService.contextChange(generateHeader() ?? '');
  }


  @override
  Future<void> used(String key, String id, dynamic val, FeatureValueType valueType) async {
    await repo.used(key, id, val, valueType, attributes);
    await edgeService.poll();
  }

}