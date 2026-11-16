import 'dart:async';
import 'dart:io';

import 'package:featurehub_client_api/api.dart';
import 'package:featurehub_openfeatures_common/featurehub_openfeatures_common.dart';

import 'yaml_flag_values.dart';

/// Overrides feature values with those in a local YAML file, for
/// development and testing. Features not in the file keep their values from
/// FeatureHub.
///
/// ```yaml
/// flagValues:
///   my-boolean-flag: true
///   my-string-flag: "hello world"
///   my-number-flag: 42
///   my-json-flag:
///     warehouse: east
/// ```
///
/// The file is [filename], else the file named by `FEATUREHUB_LOCAL_YAML`,
/// else `featurehub-features.yaml` in the current directory. A missing or
/// malformed file overrides nothing.
///
/// Values are converted to the type of the feature they override: for a
/// boolean feature `true` (in any case) is true and anything else false; for
/// a number feature numbers and numeric strings; for a string feature
/// scalars as text; for a JSON feature strings as they are and anything else
/// as JSON. `~` (null) gives a boolean feature false and other features no
/// value.
///
/// It overrides locked features too. It is the Dart equivalent of the
/// TypeScript SDK's `LocalYamlValueInterceptor`, reading the same files.
class LocalYamlValueInterceptor extends ValueInterceptor {
  /// The YAML file read.
  final String path;

  Map<String, Object?> _flagValues;
  Timer? _timer;
  _FileVersion? _lastVersion;
  bool _checking = false;

  /// Reads [filename] (see [LocalYamlValueInterceptor]). If [watchForChanges]
  /// is set, checks the file every [pollInterval] and rereads it when it
  /// changes, until [close]. [environment] replaces the process environment
  /// (for tests).
  LocalYamlValueInterceptor({
    String? filename,
    bool watchForChanges = false,
    Duration pollInterval = const Duration(milliseconds: 500),
    Map<String, String>? environment,
  }) : this._(
         resolveYamlFile(filename, environment),
         watchForChanges,
         pollInterval,
       );

  LocalYamlValueInterceptor._(
    this.path,
    bool watchForChanges,
    Duration pollInterval,
  ) : _flagValues = loadFlagValues(path) {
    if (watchForChanges) {
      _lastVersion = _FileVersion.of(FileStat.statSync(path));
      _timer = Timer.periodic(pollInterval, (_) => _check());
    }
  }

  /// The values read from the file, by feature key.
  Map<String, Object?> get flagValues => Map.unmodifiable(_flagValues);

  /// True while the file is being watched.
  bool get watching => _timer != null;

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final version = _FileVersion.of(await FileStat.stat(path));
      if (version != _lastVersion) {
        _lastVersion = version;
        reload();
      }
    } finally {
      _checking = false;
    }
  }

  /// Rereads the file.
  void reload() => _flagValues = loadFlagValues(path);

  /// Stops watching the file.
  @override
  void close() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  ValueMatch matched(String key, FeatureState? featureState) {
    if (!_flagValues.containsKey(key)) return ValueMatch.none;
    final value = _flagValues[key];

    switch (featureState?.type) {
      case FeatureValueType.BOOLEAN:
        return ValueMatch(
          true,
          value is bool ? value : '$value'.toLowerCase() == 'true',
        );
      case _ when value == null:
        // for every other type, null means no value
        return const ValueMatch(true, null);
      case FeatureValueType.NUMBER:
        return ValueMatch(true, switch (value) {
          num() => value,
          String() => num.tryParse(value.trim()),
          _ => null,
        });
      case FeatureValueType.STRING:
        return ValueMatch(
          true,
          value is String || value is num || value is bool ? '$value' : null,
        );
      case FeatureValueType.JSON:
        return ValueMatch(true, value is String ? value : toJsonText(value));
      default:
        // FeatureHub has not delivered the feature: the value as it is
        return ValueMatch(
          true,
          value is bool || value is num || value is String
              ? value
              : toJsonText(value),
        );
    }
  }
}

/// What identifies a version of the file (as Node's `fs.watchFile` does).
class _FileVersion {
  final FileSystemEntityType type;
  final DateTime modified;
  final int size;

  _FileVersion.of(FileStat stat)
    : type = stat.type,
      modified = stat.modified,
      size = stat.size;

  @override
  bool operator ==(Object other) =>
      other is _FileVersion &&
      other.type == type &&
      other.modified == modified &&
      other.size == size;

  @override
  int get hashCode => Object.hash(type, modified, size);
}
