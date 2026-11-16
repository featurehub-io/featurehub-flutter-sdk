import 'dart:convert';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

final _log = Logger('featurehub_yaml_interceptor');

/// The file read when no file name is given and [localYamlVariable] is not
/// set.
const defaultYamlFile = 'featurehub-features.yaml';

/// The environment variable naming the YAML file.
const localYamlVariable = 'FEATUREHUB_LOCAL_YAML';

/// The file name given, else [localYamlVariable], else [defaultYamlFile].
String resolveYamlFile(String? filename, Map<String, String>? environment) {
  if (filename != null) return filename;
  final fromEnv = (environment ?? Platform.environment)[localYamlVariable];
  return fromEnv == null || fromEnv.trim().isEmpty
      ? defaultYamlFile
      : fromEnv.trim();
}

/// Reads the `flagValues` map of the YAML file at [path]. A missing,
/// unreadable or malformed file gives no values.
Map<String, Object?> loadFlagValues(String path) {
  try {
    final doc = loadYaml(File(path).readAsStringSync());
    if (doc is! Map) return {};
    final values = doc['flagValues'];
    if (values is! Map) return {};
    return {for (final e in values.entries) '${e.key}': _plain(e.value)};
  } on PathNotFoundException {
    return {};
  } catch (e) {
    _log.warning('Unable to read feature values from $path: $e');
    return {};
  }
}

/// Converts YAML nodes to plain Dart values. As in JavaScript (where YAML is
/// read by the TypeScript SDK), a whole-number double is a whole number, so
/// `1.0` gives `"1"` as a string, as it does there.
Object? _plain(Object? value) => switch (value) {
  Map() => {for (final e in value.entries) '${e.key}': _plain(e.value)},
  List() => [for (final v in value) _plain(v)],
  double()
      when value.isFinite &&
          value == value.truncateToDouble() &&
          value.abs() < 9007199254740992 =>
    value.toInt(),
  _ => value,
};

/// JSON text for a value, or null if it cannot be encoded (e.g. `.nan`).
String? toJsonText(Object? value) {
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return null;
  }
}

/// The feature type a YAML value implies.
FeatureValueType detectFeatureValueType(Object? value) => switch (value) {
  bool() => FeatureValueType.BOOLEAN,
  null => FeatureValueType.STRING,
  String() =>
    value.toLowerCase() == 'true' || value.toLowerCase() == 'false'
        ? FeatureValueType.BOOLEAN
        : FeatureValueType.STRING,
  num() => FeatureValueType.NUMBER,
  _ => FeatureValueType.JSON,
};

/// A YAML value as a value of feature type [type].
Object? prepareFeatureValue(FeatureValueType type, Object? value) {
  if (type == FeatureValueType.BOOLEAN) {
    return value is bool ? value : '$value'.toLowerCase() == 'true';
  }
  if (type == FeatureValueType.STRING) {
    return value?.toString();
  }
  if (type == FeatureValueType.NUMBER) return value;
  return toJsonText(value);
}
