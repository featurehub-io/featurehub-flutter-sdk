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
    onStale: (cause) => events.add('stale ${cause.name}'),
    onFlagsChanged: (keys) => events.add('changed $keys'),
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

  test('a lost connection (bye) is not stale', () async {
    track();
    repo.notify(SSEResultState.bye, null);
    await _pump();
    repo.notify(SSEResultState.features, [_pastry]);
    await _pump();
    expect(events, isEmpty);
    expect(tracker!.stale, false);
  });

  test('a stale environment is stale once, and the features stay', () async {
    track();
    repo.markEnvironmentStale();
    repo.markEnvironmentStale();
    await _pump();

    expect(events, ['stale environmentStale']);
    expect(tracker!.stale, true);
    expect(repo.readyness, Readyness.Stale);
    expect(repo.evaluate('kwong-pastry').value, 'mango');
  });

  test('a failure after features is stale, and the features stay', () async {
    track();
    repo.notify(SSEResultState.failure, null);
    await _pump();

    expect(events, ['stale connectionFailed']);
    expect(tracker!.stale, true);
    expect(repo.evaluate('kwong-pastry').value, 'mango');
  });

  test('stale is reported once, whatever comes after', () async {
    track();
    repo.markEnvironmentStale();
    await _pump();
    repo.notify(SSEResultState.failure, null);
    repo.notify(SSEResultState.features, [_pastry]);
    await _pump();
    expect(events, ['stale environmentStale']);
  });

  test('a source already stopped is reported after creation', () async {
    repo.markEnvironmentStale();
    track();
    expect(events, isEmpty, reason: 'after the provider reports ready');
    await _pump();
    expect(events, ['stale environmentStale']);
  });
}
