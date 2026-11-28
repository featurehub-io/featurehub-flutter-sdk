// A WebAssembly build check, compiled by CI (`dart compile wasm`): it pulls in
// the package's public libraries, with their browser variants (the SSE
// listener on `EventSource`), so a change that is not compatible with dart2wasm
// (an unconditional `dart:io` import, a JS interop API dart2wasm does not
// support) fails the build. It is not run.
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';

Future<void> main() async {
  final connection = FeatureHubConnection(
    host: 'http://localhost:8064',
    apiKey: 'env/key*secret',
  );
  await connection.start();
  await connection.waitForReady(const Duration(seconds: 1));
  final evaluation = connection.repository.evaluate('flag');
  resolveFromEvaluation('flag', FeatureKind.boolean, false, evaluation);
  await connection.close();
}
