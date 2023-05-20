import 'dart:io';

import 'package:featurehub_client_sdk/featurehub.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:logging/logging.dart';

void main() async {
  Logger.root.level = Level.ALL; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
    if (record.object != null) {
      // ignore: avoid_print
      print('exception:${record.object}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('stackTrace:${record.stackTrace}');
    }
  });

  final apiKey = Platform.environment['FEATUREHUB_SERVER_API_KEY'];
  final hostUrl = Platform.environment['FEATUREHUB_EDGE_URL'];

  if (apiKey == null || hostUrl == null) {
    // ignore: avoid_print
    print('Please set the FEATUREHUB_SERVER_API_KEY and FEATUREHUB_EDGE_URL values.');
    exit(-1);
  }

  var config = FeatureHubConfig(hostUrl, [apiKey]).timeout(5);

  if (Platform.environment['STREAMING'] != null) {
    config = config.streaming();
  }

  final repo = config.repository;

  config.readinessStream.listen((ready) {
    // ignore: avoid_print
    print('readyness $ready');
  });

  final ctx = await config.newContext()
      .userKey(Platform.environment['USERKEY'] ?? 'some_unique_user_id')
      .device(StrategyAttributeDeviceName.desktop)
      .platform(StrategyAttributePlatformName.macos)
      .attr('age', '21')
      .build();

  repo.newFeatureStateAvailableStream.listen((event) {
    repo.availableFeatures.forEach((key) {
      final feature = ctx.feature(key);
      final repoFeature = repo.feature(key);
      // ignore: avoid_print
      print(
          'feature $key is of type ${feature.type} and has the value (context) ${feature.value} vs repo ${repoFeature.value}');
    });
  });

  // ignore: avoid_print
  print('hit <enter> to cancel');
  await stdin.first;
}
