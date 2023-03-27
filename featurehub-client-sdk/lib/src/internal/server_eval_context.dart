

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_client_sdk/src/internal/internal_context.dart';
import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';

class ServerEvalClientContext extends InternalContext {
  ServerEvalClientContext(InternalFeatureRepository repo) : super(repo);

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
  used(String key, String id, val, FeatureValueType valueType) {
    // TODO: implement used
    throw UnimplementedError();
  }

}