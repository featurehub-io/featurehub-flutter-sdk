import 'package:featurehub_client_sdk/src/internal/internal_repository.dart';
import 'package:meta/meta.dart';

import '../config.dart';

@internal
class EdgeStreaming implements EdgeService {
  EdgeStreaming(FeatureHub config, InternalFeatureRepository repository);

  void close() {
    throw UnimplementedError('This is implemented in the concrete version');
  }

  @override
  Future<void> contextChange(String header) {
    throw UnimplementedError();
  }

  @override
  Future<void> poll() {
    throw UnimplementedError();
  }

  @override
  bool get stopped => throw UnimplementedError();
}
