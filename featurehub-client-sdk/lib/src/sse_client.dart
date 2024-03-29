import 'repository.dart';

class EventSourceRepositoryListener {
  EventSourceRepositoryListener(
      String hostUrl, String apiKey, ClientFeatureRepository repository,
      {bool doInit = true});

  void close() {
    throw UnimplementedError('This is implemented in the concrete version');
  }

  bool get closed => false;

  Future<void> init() {
    throw UnimplementedError('This is implemented in the concrete version');
  }
}
