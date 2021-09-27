import 'repository.dart';

/// this is a stub implementation, you shouldn't get it if you use dart:io or dart:html
/// which is pretty much every option
class EventSourceRepositoryListener {
  EventSourceRepositoryListener(
      String hostUrl, String apiKey, ClientFeatureRepository repository,
      {bool doInit = true});

  void close() {
    throw UnimplementedError('This is implemented in the concrete version');
  }

  Future<void> init() {
    throw UnimplementedError('This is implemented in the concrete version');
  }
}
