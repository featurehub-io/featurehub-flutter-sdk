import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';
import 'package:featurehub_openfeatures_yaml_interceptor/featurehub_openfeatures_yaml_interceptor.dart';
import 'package:test/test.dart';

FeatureState _state(FeatureValueType type, {bool locked = false}) =>
    FeatureState(id: 'id', key: 'flag', version: 1, type: type, l: locked);

void main() {
  late Directory dir;
  late String yamlFile;
  final opened = <LocalYamlValueInterceptor>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('fh_yaml');
    yamlFile = '${dir.path}/features.yaml';
  });

  tearDown(() {
    for (final i in opened) {
      i.close();
    }
    opened.clear();
    dir.deleteSync(recursive: true);
  });

  void write(String content) => File(yamlFile).writeAsStringSync(content);

  LocalYamlValueInterceptor interceptor(String content, {bool watch = false}) {
    write(content);
    final i = LocalYamlValueInterceptor(
      filename: yamlFile,
      watchForChanges: watch,
      pollInterval: const Duration(milliseconds: 20),
    );
    opened.add(i);
    return i;
  }

  /// [matched, value] for [key], as the TypeScript tests express it.
  List<Object?> match(
    LocalYamlValueInterceptor i,
    String key, [
    FeatureValueType? type,
  ]) {
    final vm = i.matched(key, type == null ? null : _state(type));
    return [vm.matched, vm.value];
  }

  group('the file', () {
    test('is the one given', () {
      final i = interceptor('flagValues:\n  flag: true\n');
      expect(i.path, yamlFile);
      expect(match(i, 'flag'), [true, true]);
    });

    test('is otherwise named by FEATUREHUB_LOCAL_YAML', () {
      write('flagValues:\n  flag: 42\n');
      final i = LocalYamlValueInterceptor(
        environment: {'FEATUREHUB_LOCAL_YAML': yamlFile},
      );
      expect(match(i, 'flag'), [true, 42]);
    });

    test('is otherwise featurehub-features.yaml', () {
      expect(LocalYamlValueInterceptor(environment: {}).path, defaultYamlFile);
      expect(defaultYamlFile, 'featurehub-features.yaml');
    });

    test('overrides nothing when it does not exist', () {
      final i = LocalYamlValueInterceptor(filename: '${dir.path}/missing.yaml');
      expect(match(i, 'anything'), [false, null]);
    });

    test('overrides nothing without flagValues', () {
      expect(match(interceptor('otherKey: someValue\n'), 'otherKey'), [
        false,
        null,
      ]);
    });

    test('overrides nothing with empty flagValues', () {
      expect(match(interceptor('flagValues: {}\n'), 'anything'), [false, null]);
    });

    test('overrides nothing when malformed', () {
      expect(match(interceptor('flagValues: [unclosed\n'), 'flag'), [
        false,
        null,
      ]);
    });
  });

  group('without a feature from FeatureHub', () {
    test('does not match an absent key', () {
      expect(match(interceptor('flagValues:\n  other: 1\n'), 'missing'), [
        false,
        null,
      ]);
    });

    test('gives the values as they are', () {
      final i = interceptor(
        'flagValues:\n  t: true\n  f: false\n  n: 42\n  d: 3.14\n'
        '  s: hello\n  z: ~\n',
      );
      expect(match(i, 't'), [true, true]);
      expect(match(i, 'f'), [true, false]);
      expect(match(i, 'n'), [true, 42]);
      expect(match(i, 'd'), [true, 3.14]);
      expect(match(i, 's'), [true, 'hello']);
      expect(match(i, 'z'), [true, null]);
    });

    test('gives maps and lists as JSON', () {
      final i = interceptor(
        'flagValues:\n  o:\n    a: 1\n    b: two\n  l:\n    - 1\n    - x\n',
      );
      expect(jsonDecode(match(i, 'o')[1] as String), {'a': 1, 'b': 'two'});
      expect(jsonDecode(match(i, 'l')[1] as String), [1, 'x']);
    });
  });

  group('for a boolean feature', () {
    const b = FeatureValueType.BOOLEAN;

    test('null is false', () {
      expect(match(interceptor('flagValues:\n  f: ~\n'), 'f', b), [
        true,
        false,
      ]);
    });

    test('booleans are themselves', () {
      final i = interceptor('flagValues:\n  t: true\n  f: false\n');
      expect(match(i, 't', b), [true, true]);
      expect(match(i, 'f', b), [true, false]);
    });

    test('"true" in any case is true, anything else false', () {
      final i = interceptor(
        'flagValues:\n  a: "true"\n  b: "TRUE"\n  c: "false"\n  d: 1\n'
        '  e: 0\n',
      );
      expect(match(i, 'a', b), [true, true]);
      expect(match(i, 'b', b), [true, true]);
      expect(match(i, 'c', b), [true, false]);
      expect(match(i, 'd', b), [true, false]);
      expect(match(i, 'e', b), [true, false]);
    });
  });

  group('for a number feature', () {
    const n = FeatureValueType.NUMBER;

    test('null is no value', () {
      expect(match(interceptor('flagValues:\n  f: ~\n'), 'f', n), [true, null]);
    });

    test('numbers are themselves, numeric strings are converted', () {
      final i = interceptor(
        'flagValues:\n  a: 5\n  b: 2.5\n  c: "99"\n  d: nope\n  e:\n'
        '    x: 1\n',
      );
      expect(match(i, 'a', n), [true, 5]);
      expect(match(i, 'b', n), [true, 2.5]);
      expect(match(i, 'c', n), [true, 99]);
      expect(match(i, 'd', n), [true, null]);
      expect(match(i, 'e', n), [true, null]);
    });
  });

  group('for a string feature', () {
    const s = FeatureValueType.STRING;

    test('null is no value', () {
      expect(match(interceptor('flagValues:\n  f: ~\n'), 'f', s), [true, null]);
    });

    test('scalars are text, maps and lists no value', () {
      final i = interceptor(
        'flagValues:\n  a: hi\n  b: 7\n  c: true\n  d: 1.0\n  e:\n    x: 1\n',
      );
      expect(match(i, 'a', s), [true, 'hi']);
      expect(match(i, 'b', s), [true, '7']);
      expect(match(i, 'c', s), [true, 'true']);
      // a whole number, as in JavaScript
      expect(match(i, 'd', s), [true, '1']);
      expect(match(i, 'e', s), [true, null]);
    });
  });

  group('for a JSON feature', () {
    const j = FeatureValueType.JSON;

    test('null is no value', () {
      expect(match(interceptor('flagValues:\n  f: ~\n'), 'f', j), [true, null]);
    });

    test('maps, lists and scalars are JSON; strings are as they are', () {
      final i = interceptor(
        'flagValues:\n  o:\n    a: 1\n  l:\n    - 1\n    - 2\n'
        '  s: \'{"a":1}\'\n  n: 42\n',
      );
      expect(match(i, 'o', j), [true, '{"a":1}']);
      expect(match(i, 'l', j), [true, '[1,2]']);
      expect(match(i, 's', j), [true, '{"a":1}']);
      expect(match(i, 'n', j), [true, '42']);
    });
  });

  group('watching the file', () {
    const settle = Duration(milliseconds: 150);

    test('is off unless asked for', () async {
      final i = interceptor('flagValues:\n  flag: true\n');
      expect(i.watching, false);
      write('flagValues:\n  flag: false\n');
      await Future<void>.delayed(settle);
      expect(match(i, 'flag'), [true, true]);
    });

    test('picks up changed, added and removed values', () async {
      final i = interceptor(
        'flagValues:\n  flag: true\n  gone: 1\n',
        watch: true,
      );
      expect(i.watching, true);
      write('flagValues:\n  flag: false\n  added: 42\n');
      await Future<void>.delayed(settle);
      expect(match(i, 'flag'), [true, false]);
      expect(match(i, 'added'), [true, 42]);
      expect(match(i, 'gone'), [false, null]);
    });

    test('picks up a file created later, and its removal', () async {
      final i = LocalYamlValueInterceptor(
        filename: yamlFile,
        watchForChanges: true,
        pollInterval: const Duration(milliseconds: 20),
      );
      opened.add(i);
      expect(match(i, 'flag'), [false, null]);
      write('flagValues:\n  flag: on\n');
      await Future<void>.delayed(settle);
      expect(match(i, 'flag'), [true, 'on']);
      File(yamlFile).deleteSync();
      await Future<void>.delayed(settle);
      expect(match(i, 'flag'), [false, null]);
    });

    test('stops on close, which can be repeated', () async {
      final i = interceptor('flagValues:\n  flag: true\n', watch: true);
      i.close();
      i.close();
      expect(i.watching, false);
      write('flagValues:\n  flag: false\n');
      await Future<void>.delayed(settle);
      expect(match(i, 'flag'), [true, true]);
    });

    test('reload rereads the file', () {
      final i = interceptor('flagValues:\n  flag: true\n');
      write('flagValues:\n  flag: false\n');
      i.reload();
      expect(match(i, 'flag'), [true, false]);
    });
  });

  group('in a repository', () {
    late ClientFeatureRepository repo;

    setUp(() {
      repo = ClientFeatureRepository();
      repo.notify(SSEResultState.features, [
        FeatureState(
          id: '1',
          key: 'bool',
          version: 1,
          type: FeatureValueType.BOOLEAN,
          value: false,
        ),
        FeatureState(
          id: '2',
          key: 'locked',
          version: 1,
          type: FeatureValueType.NUMBER,
          value: 1,
          l: true,
        ),
        FeatureState(
          id: '3',
          key: 'json',
          version: 1,
          type: FeatureValueType.JSON,
          value: '{}',
        ),
        FeatureState(
          id: '4',
          key: 'untouched',
          version: 1,
          type: FeatureValueType.STRING,
          value: 'from FeatureHub',
        ),
      ]);
      repo.addValueInterceptor(
        interceptor(
          'flagValues:\n  bool: "TRUE"\n  locked: "12"\n  json:\n    a: 1\n',
        ),
      );
    });

    tearDown(() => repo.shutdown());

    test('overrides the features in the file, typed as the feature', () {
      expect(repo.evaluate('bool').value, true);
      expect(repo.evaluate('bool').intercepted, true);
      expect(repo.evaluate('json').value, '{"a":1}');
      expect(repo.feature('bool').booleanValue, true);
      expect(repo.feature('json').jsonValue, {'a': 1});
    });

    test('overrides locked features', () {
      expect(repo.evaluate('locked').value, 12);
      expect(repo.feature('locked').numberValue, 12);
    });

    test('leaves the other features alone', () {
      expect(repo.evaluate('untouched').value, 'from FeatureHub');
      expect(repo.evaluate('untouched').intercepted, false);
    });

    test('resolves through OpenFeature resolution', () {
      final r = resolveFromEvaluation(
        'json',
        FeatureKind.object,
        <String, Object?>{},
        repo.evaluate('json'),
      );
      expect(r.value, {'a': 1});
      expect(r.isError, false);
    });

    test('is closed when the repository shuts down', () {
      final watched = interceptor('flagValues: {}\n', watch: true);
      final other = ClientFeatureRepository()..addValueInterceptor(watched);
      other.shutdown();
      expect(watched.watching, false);
    });
  });
}
