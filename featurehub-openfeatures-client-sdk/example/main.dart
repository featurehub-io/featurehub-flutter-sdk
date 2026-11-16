// A minimal (non-Flutter) example; in a Flutter app the calls are the same.
//
//   dart run example/main.dart <edge url> '<server-evaluated api key>'
import 'package:featurehub_openfeatures_client_sdk/featurehub_openfeatures_client_sdk.dart';
import 'package:openfeature_dart_client_sdk/openfeature_dart_client_sdk.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    // ignore: avoid_print
    print('usage: dart run example/main.dart <edge url> <api key>');
    return;
  }

  final api = OpenFeatureAPI.instance;

  // the context features are evaluated for
  await api.setEvaluationContextAndWait(
    EvaluationContext(
      targetingKey: 'user-123',
      attributes: {'country': 'new_zealand', 'platform': 'ios'},
    ),
  );
  await api.setProviderAndWait(
    FeatureHubProvider(host: args[0], apiKey: args[1]),
  );

  final client = api.getClient();
  // react to feature changes, e.g. to rebuild a widget
  client.addHandler(ProviderEventType.configurationChanged, (details) {
    // ignore: avoid_print
    print('changed: ${details.flagsChanged}');
  });

  final details = client.getBooleanDetails('new-checkout', false);
  // ignore: avoid_print
  print('new-checkout=${details.value} (${details.reason})');

  // a new user: the provider fetches their features before this completes
  await api.setEvaluationContextAndWait(
    EvaluationContext(targetingKey: 'user-456'),
  );
  // ignore: avoid_print
  print('new-checkout=${client.getBooleanValue('new-checkout', false)}');

  await api.shutdown();
}
