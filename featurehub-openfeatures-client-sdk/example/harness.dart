// The harness of the todo-server end-to-end tests (todo_server_test.dart),
// as featurehub-sdk-docs specs/todo-server-tests.yaml describes it: it
// changes features with this SDK's feature updater, watches for each change
// with this SDK's client provider, and talks to the todo server under test.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:featurehub_client_api/api.dart' show FeatureState;
import 'package:featurehub_openfeatures_client_sdk/featurehub_openfeatures_client_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:openfeature_dart_client_sdk/openfeature_dart_client_sdk.dart';
import 'package:test/test.dart';

/// The settings, from the environment (environment.variables).
class HarnessConfig {
  /// The todo server under test.
  final Uri appServer;

  /// FeatureHub Edge, for the updater (and the client, unless [snapshotUrl]).
  final String edgeUrl;

  /// A client-evaluated key with READ, CHANGE_VALUE, LOCK and UNLOCK.
  final String apiKey;

  /// The todo server's poll interval (and the harness's), or null when both
  /// stream.
  final Duration? pollInterval;

  /// The todo server's `GET /features`, when the client reads its features
  /// from there.
  final String? snapshotUrl;

  HarnessConfig({
    required this.appServer,
    required this.edgeUrl,
    required this.apiKey,
    this.pollInterval,
    this.snapshotUrl,
  });

  /// From [environment] (by default the process's). Throws a [StateError]
  /// naming what is missing or invalid.
  factory HarnessConfig.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    String? read(String name) {
      final value = env[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final edgeUrl = read('FEATUREHUB_EDGE_URL');
    final apiKey = read('FEATUREHUB_CLIENT_API_KEY');
    if (edgeUrl == null || apiKey == null) {
      throw StateError(
        'Set FEATUREHUB_EDGE_URL and FEATUREHUB_CLIENT_API_KEY (a '
        'client-evaluated key with read, change value, lock and unlock '
        'permissions), and APP_SERVER_URL for the todo server',
      );
    }
    final interval = read('FEATUREHUB_CONNECT_INTERVAL');
    final pollInterval = interval == null ? null : parseDuration(interval);
    if (interval != null &&
        (pollInterval == null || pollInterval < const Duration(seconds: 5))) {
      throw StateError(
        'FEATUREHUB_CONNECT_INTERVAL must be a duration of at least 5s, such '
        'as 5s or 30s, not "$interval"',
      );
    }
    return HarnessConfig(
      appServer: Uri.parse(read('APP_SERVER_URL') ?? 'http://localhost:8099'),
      edgeUrl: edgeUrl,
      apiKey: apiKey,
      pollInterval: pollInterval,
      snapshotUrl: read('FEATUREHUB_SNAPSHOT_URL'),
    );
  }

  /// How long the client may take to see a change
  /// (harness.awaiting_a_change.timeout).
  Duration get changeTimeout {
    final poll = pollInterval;
    var timeout = poll == null
        ? const Duration(seconds: 7)
        : poll + const Duration(seconds: 4);
    if (snapshotUrl != null) timeout += poll ?? const Duration(seconds: 5);
    return timeout;
  }

  /// A duration as the FeatureHub environment variables take it: one number
  /// and a unit (ms, s, m or h), or 0. Null if [value] is not one.
  static Duration? parseDuration(String value) {
    final match = RegExp(
      r'^(0|([0-9]+(\.[0-9]+)?)(ms|s|m|h))$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    if (match[1] == '0') return Duration.zero;
    final amount = double.parse(match[2]!);
    final unit = switch (match[4]) {
      'ms' => Duration.microsecondsPerMillisecond,
      's' => Duration.microsecondsPerSecond,
      'm' => Duration.microsecondsPerMinute,
      _ => Duration.microsecondsPerHour,
    };
    return Duration(microseconds: (amount * unit).round());
  }
}

/// Runs [check] until it passes, every [every], for up to [timeout]; then
/// runs it once more, so its failure is the test's.
Future<void> eventually(
  FutureOr<void> Function() check, {
  required Duration timeout,
  Duration every = const Duration(seconds: 1),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    try {
      await check();
      return;
    } on TestFailure {
      await Future<void>.delayed(every);
    }
  }
  await check();
}

/// The value a scenario sets a feature to: [notSet] for none.
const notSet = Object();

/// Changes features with [FeatureHubFeatureUpdater] and watches for each
/// change with the client provider.
class FeatureHarness {
  final HarnessConfig config;
  final FeatureHubFeatureUpdater updater;
  final FeatureHubProvider provider;

  FeatureHarness._(this.config, this.updater, this.provider);

  /// Starts the client provider (streaming, or polling at the configured
  /// interval, from Edge or from the todo server's snapshot).
  static Future<FeatureHarness> start(HarnessConfig config) async {
    final poll = config.pollInterval;
    final snapshot = config.snapshotUrl;
    final provider = snapshot != null
        ? FeatureHubProvider(
            featuresUrl: snapshot,
            mode: FeatureHubUpdateMode.activePolling,
            pollInterval: poll ?? const Duration(seconds: 5),
          )
        : FeatureHubProvider(
            host: config.edgeUrl,
            apiKey: config.apiKey,
            mode: poll == null
                ? FeatureHubUpdateMode.streaming
                : FeatureHubUpdateMode.activePolling,
            pollInterval: poll ?? const Duration(seconds: 30),
          );
    final api = OpenFeatureAPI.instance;
    await api.setEvaluationContextAndWait(
      EvaluationContext(targetingKey: 'todo-server-tests'),
    );
    await api.setProviderAndWait(provider);
    return FeatureHarness._(
      config,
      FeatureHubFeatureUpdater(host: config.edgeUrl, apiKey: config.apiKey),
      provider,
    );
  }

  OpenFeatureClient get _client => OpenFeatureAPI.instance.getClient();

  /// The feature as the client last received it.
  FeatureState? state(String key) {
    for (final feature
        in provider.repository?.featureStates ?? const <FeatureState>[]) {
      if (feature.key == key) return feature;
    }
    return null;
  }

  /// Whether the client holds [key] with no value. (Resolving it would not
  /// tell, for a feature of another type than the one asked for.)
  bool isNotSet(String key) {
    final feature = state(key);
    return feature != null && feature.value == null;
  }

  /// Expects the client to see [value] ([notSet] for none) for [key], whose
  /// type [value] gives, and the lock, when [locked] is given.
  void expectSees(String key, Object? value, {bool? locked}) {
    if (locked != null) {
      expect(state(key)?.l ?? false, locked, reason: '$key locked');
    }
    if (identical(value, notSet)) {
      expect(isNotSet(key), true, reason: '$key is not set');
      return;
    }
    switch (value) {
      case bool flag:
        expect(_client.getBooleanValue(key, !flag), flag, reason: key);
      case num number:
        expect(
          _client.getDoubleValue(key, number.toDouble() + 1),
          number.toDouble(),
          reason: key,
        );
      case Map<String, Object?> json:
        expect(_client.getStructureValue(key, const {}), json, reason: key);
      case String text:
        expect(
          _client.getStringDetails(key, '\u0000').value,
          text,
          reason: key,
        );
      default:
        throw ArgumentError.value(value, 'value');
    }
  }

  /// Sends [update] for [key] and returns Edge's answer.
  Future<FeatureUpdateResult> send(String key, FeatureUpdate update) async {
    final result = await updater.update(key, update);
    printOnFailure('update $key $update -> $result');
    return result;
  }

  /// Unlocks [key] and sets it to [value] ([notSet] for none), expecting
  /// Edge to accept it, then waits until the client sees it
  /// (harness.updates, harness.awaiting_a_change).
  Future<void> set(String key, Object? value) async {
    final result = await send(
      key,
      identical(value, notSet)
          ? const FeatureUpdate.clear(lock: false)
          : FeatureUpdate.value(value, lock: false),
    );
    expect(result.success, true, reason: 'setting $key: $result');
    await eventually(
      () => expectSees(key, value, locked: false),
      timeout: config.changeTimeout,
      every: const Duration(seconds: 1),
    );
  }

  /// Locks or unlocks [key] and waits until the client sees it, sending the
  /// change again every third read (harness.awaiting_a_change.lost_updates).
  Future<void> lock(String key, {required bool locked}) async {
    final result = await send(key, FeatureUpdate.lock(locked));
    expect(result.success, true, reason: 'locking $key: $result');
    var reads = 0;
    await eventually(
      () async {
        reads++;
        if (reads % 3 == 0 && (state(key)?.l ?? false) != locked) {
          await send(key, FeatureUpdate.lock(locked));
        }
        expect(state(key)?.l ?? false, locked, reason: '$key locked');
      },
      timeout: config.changeTimeout,
      every: const Duration(milliseconds: 500),
    );
  }

  Future<void> close() async {
    updater.close();
    await OpenFeatureAPI.instance.shutdown();
  }
}

/// The todo server's API (todo_api).
class TodoApi {
  final Uri base;
  final http.Client _http = http.Client();

  TodoApi(this.base);

  Uri _user(String user) => base.resolve('todo/${Uri.encodeComponent(user)}');

  /// Waits for the server to be ready (GET /health/readiness).
  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      try {
        final response = await _http.get(base.resolve('health/readiness'));
        if (response.statusCode == 200) return;
      } on Exception {
        // not up yet
      }
      if (DateTime.now().isAfter(end)) {
        fail('the todo server at $base was not ready within $timeout');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  /// DELETE /todo/{user}.
  Future<void> removeAll(String user) async {
    final response = await _http.delete(_user(user));
    expect(response.statusCode ~/ 100, 2, reason: 'DELETE ${_user(user)}');
  }

  /// POST /todo/{user}.
  Future<void> add(String user, String title) async {
    final response = await _http.post(
      _user(user),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'id': '1', 'title': title}),
    );
    expect(response.statusCode ~/ 100, 2, reason: 'POST ${_user(user)}');
  }

  /// GET /todo/{user}: the titles.
  Future<List<String>> titles(String user) async {
    final response = await _http.get(_user(user));
    expect(response.statusCode, 200, reason: 'GET ${_user(user)}');
    return [
      for (final todo in jsonDecode(response.body) as List)
        (todo as Map)['title'] as String,
    ];
  }

  /// Waits until the user's list has a todo titled exactly [title]
  /// (harness.list_contains).
  Future<void> expectListContains(String user, String title) => eventually(
    () async => expect(await titles(user), contains(title)),
    timeout: const Duration(seconds: 20),
  );

  void close() => _http.close();
}
