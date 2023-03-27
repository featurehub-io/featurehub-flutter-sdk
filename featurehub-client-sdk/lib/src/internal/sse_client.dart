import 'package:meta/meta.dart';

import '../config.dart';
import 'repository.dart';

@internal
class EventSourceRepositoryListener implements EdgeService {
  EventSourceRepositoryListener(
      String hostUrl, String apiKey, ClientFeatureRepository repository,
      {bool doInit = true});

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
