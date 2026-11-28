// The FeatureHub todo-server end-to-end tests (featurehub-sdk-docs
// specs/todo-server-tests.yaml), with this SDK as the harness: its feature
// updater changes features in FeatureHub, its client provider watches for
// each change, and the todo server under test (any language, any FeatureHub
// SDK) must pick it up. See README.md here for how to run them.
//
//   APP_SERVER_URL=http://localhost:8099 \
//   FEATUREHUB_EDGE_URL=http://localhost:8085 \
//   FEATUREHUB_CLIENT_API_KEY='default/<environment>/<client-evaluated key>' \
//   dart test example/todo_server_test.dart
//
// Add -t todo-api to check only the todo server (and its SDK), or
// -t featurehub-only to check only this SDK's updater and client.
@Timeout(Duration(minutes: 2))
library;

import 'package:featurehub_openfeatures_client_sdk/featurehub_openfeatures_client_sdk.dart';
import 'package:test/test.dart';

import 'harness.dart';

const uppercase = 'FEATURE_TITLE_TO_UPPERCASE';
const string = 'FEATURE_STRING';
const number = 'FEATURE_NUMBER';
const json = 'FEATURE_JSON';

/// The user whose todo list the scenarios use.
const user = 'lingling';

void main() {
  late HarnessConfig config;
  late FeatureHarness features;
  late TodoApi todos;

  setUpAll(() async {
    config = HarnessConfig.fromEnvironment();
    todos = TodoApi(config.appServer);
    await todos.waitUntilReady();
    features = await FeatureHarness.start(config);
  });

  tearDownAll(() async {
    todos.close();
    await features.close();
  });

  /// A todo-api scenario (scenarios): sets [feature] to [value] (with
  /// FEATURE_TITLE_TO_UPPERCASE off first, unless it is the feature), adds
  /// [add] to a fresh list, and expects [expected] in it.
  void todoScenario(
    String id,
    String feature,
    Object? value, {
    required String add,
    required String expected,
  }) {
    test(id, tags: 'todo-api', () async {
      if (feature != uppercase) await features.set(uppercase, false);
      await features.set(feature, value);
      // boolean-on leaves the flag off again (harness.after)
      if (feature == uppercase && value == true) {
        addTearDown(() => features.set(uppercase, false));
      }

      await todos.removeAll(user);
      await todos.add(user, add);
      await todos.expectListContains(user, expected);
    });
  }

  group('FEATURE_TITLE_TO_UPPERCASE', () {
    todoScenario(
      'boolean-on',
      uppercase,
      true,
      add: 'Buy eggs',
      expected: 'BUY EGGS',
    );
    todoScenario(
      'boolean-off',
      uppercase,
      false,
      add: 'Buy eggs',
      expected: 'Buy eggs',
    );
  });

  group('FEATURE_STRING', () {
    todoScenario(
      'string-milk',
      string,
      'milk',
      add: 'buy',
      expected: 'buy milk',
    );
    todoScenario(
      'string-bread',
      string,
      'bread',
      add: 'buy',
      expected: 'buy bread',
    );
    todoScenario(
      'string-multiple-words',
      string,
      'foo bar baz',
      add: 'buy',
      expected: 'buy foo bar baz',
    );
    todoScenario('string-empty', string, '', add: 'buy', expected: 'buy ');
    todoScenario('string-not-set', string, notSet, add: 'buy', expected: 'buy');
  });

  group('FEATURE_NUMBER', () {
    todoScenario('number-one', number, 1, add: 'pay', expected: 'pay 1');
    todoScenario(
      'number-decimal',
      number,
      507598.258978,
      add: 'pay',
      expected: 'pay 507598.258978',
    );
    todoScenario('number-zero', number, 0, add: 'pay', expected: 'pay 0');
    todoScenario(
      'number-negative',
      number,
      -16746.43,
      add: 'pay',
      expected: 'pay -16746.43',
    );
    todoScenario('number-not-set', number, notSet, add: 'pay', expected: 'pay');
  });

  group('FEATURE_JSON', () {
    todoScenario(
      'json-bar',
      json,
      const {'foo': 'bar'},
      add: 'find',
      expected: 'find bar',
    );
    todoScenario(
      'json-baz',
      json,
      const {'foo': 'baz'},
      add: 'find',
      expected: 'find baz',
    );
    todoScenario('json-not-set', json, notSet, add: 'find', expected: 'find');
  });

  group('the feature updater and locking', () {
    /// Sets [feature] to [value], locks it, then expects a value-only update
    /// to [attempt] (not unlocking) to be refused as not possible.
    Future<void> lockScenario(
      String feature,
      Object value,
      Object attempt,
    ) async {
      await features.set(feature, value);
      await features.lock(feature, locked: true);
      await eventually(
        () => features.expectSees(feature, value, locked: true),
        timeout: config.changeTimeout,
      );

      final result = await features.send(feature, FeatureUpdate.value(attempt));
      expect(result.success, false, reason: '$result');
      expect(result.outcome, FeatureUpdateOutcome.notPossible);
      features.expectSees(feature, value, locked: true);
    }

    /// Expects setting [feature] (unlocked) to [value] to be refused as
    /// invalid for its type.
    Future<void> rejectsScenario(String feature, Object value) async {
      final result = await features.send(
        feature,
        FeatureUpdate.value(value, lock: false),
      );
      expect(result.success, false, reason: '$result');
      expect(result.outcome, FeatureUpdateOutcome.invalid);
    }

    test(
      'boolean-lock',
      tags: 'featurehub-only',
      () => lockScenario(uppercase, true, false),
    );
    test(
      'boolean-rejects-string',
      tags: 'featurehub-only',
      () => rejectsScenario(uppercase, 'foo'),
    );
    test(
      'number-lock',
      tags: 'featurehub-only',
      () => lockScenario(number, 26, 35),
    );
    test(
      'number-rejects-string',
      tags: 'featurehub-only',
      () => rejectsScenario(number, 'foo'),
    );
    test(
      'string-lock',
      tags: 'featurehub-only',
      () => lockScenario(string, 'ugg-boots', 'run'),
    );
    test(
      'json-rejects-non-json',
      tags: 'featurehub-only',
      () => rejectsScenario(json, 'foo'),
    );
  });
}
