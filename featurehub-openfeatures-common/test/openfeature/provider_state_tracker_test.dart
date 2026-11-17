import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:test/test.dart';

final _pastry = FeatureState(
  id: 'fv-pastry',
  key: 'kwong-pastry',
  version: 1,
  type: FeatureValueType.STRING,
  value: 'mango',
);

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  late ClientFeatureRepository repo;
  late List<String> events;
  ProviderStateTracker? tracker;

  ProviderStateTracker track() => tracker = ProviderStateTracker(
    repo,
    onStale: () => events.add('stale'),
    onRecovered: () => events.add('ready'),
    onFatal: () => events.add('fatal'),
    onFlagsChanged: (keys) => events.add('changed $keys'),
    onEnvironmentStale: () => events.add('environment stale'),
  );

  setUp(() {
    repo = ClientFeatureRepository()
      ..notify(SSEResultState.features, [_pastry]);
    events = [];
  });

  tearDown(() async {
    await tracker?.cancel();
    repo.shutdown();
  });

  test('a stale environment is reported once, and the features stay', () async {
    track();
    repo.markEnvironmentStale();
    repo.markEnvironmentStale();
    await _pump();

    expect(events, ['environment stale']);
    expect(repo.environmentStale, true);
    expect(repo.readyness, Readyness.Ready);
    expect(repo.evaluate('kwong-pastry').value, 'mango');
  });

  test('an environment already stale is reported after creation', () async {
    repo.markEnvironmentStale();
    track();
    expect(events, isEmpty, reason: 'after the provider reports ready');
    await _pump();
    expect(events, ['environment stale']);
  });

  test('a stale environment never recovers, nor goes stale again', () async {
    track();
    repo.markEnvironmentStale();
    await _pump();

    repo.notify(SSEResultState.bye, null);
    await _pump();
    repo.notify(SSEResultState.features, [_pastry]);
    await _pump();
    expect(events, ['environment stale']);

    // a rejection is still reported
    repo.notify(SSEResultState.failure, null);
    await _pump();
    expect(events, ['environment stale', 'fatal']);
  });

  test('a lost connection is stale, then recovers', () async {
    track();
    repo.notify(SSEResultState.bye, null);
    await _pump();
    repo.notify(SSEResultState.features, [_pastry]);
    await _pump();
    expect(events, ['stale', 'ready']);
  });
}
