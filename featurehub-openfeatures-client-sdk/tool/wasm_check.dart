// A WebAssembly build check, compiled by CI (`dart compile wasm`): it pulls in
// the provider and everything it depends on, with their browser variants (the
// SSE listener on `EventSource`), so a change that is not compatible with
// dart2wasm (an unconditional `dart:io` import, a JS interop API dart2wasm does
// not support) fails the build. It is not run.
import 'package:featurehub_openfeatures_client_sdk/featurehub_openfeatures_client_sdk.dart';
import 'package:openfeature_dart_client_sdk/openfeature_dart_client_sdk.dart';

Future<void> main() async {
  final api = OpenFeatureAPI.instance;
  for (final mode in FeatureHubUpdateMode.values) {
    await api.setProviderAndWait(
      FeatureHubProvider(
        host: 'http://localhost:8064',
        apiKey: 'env/key',
        mode: mode,
      ),
    );
    api.getClient().getBooleanValue('flag', false);
  }
  await api.shutdown();
}
