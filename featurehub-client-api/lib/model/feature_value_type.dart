part of featurehub_client_api.api;

// This file is generated by https://github.com/dart-ogurets/dart-openapi-maven - you should not modify it
// log generation bugs on Github, as part of the license, you must not remove these headers from the Mustache templates.
// this project is maintained as part of FeatureHub - please consider sponsoring us at https://github.com/featurehub-io

enum FeatureValueType { BOOLEAN, STRING, NUMBER, JSON }

extension FeatureValueTypeExtension on FeatureValueType {
  String? get name => toMap[this];

  // you have to call this extension class to use this as this is not yet supported
  static FeatureValueType? type(String name) => fromMap[name];

  static Map<String, FeatureValueType> fromMap = {
    'BOOLEAN': FeatureValueType.BOOLEAN,
    'STRING': FeatureValueType.STRING,
    'NUMBER': FeatureValueType.NUMBER,
    'JSON': FeatureValueType.JSON
  };
  static Map<FeatureValueType, String> toMap = {
    FeatureValueType.BOOLEAN: 'BOOLEAN',
    FeatureValueType.STRING: 'STRING',
    FeatureValueType.NUMBER: 'NUMBER',
    FeatureValueType.JSON: 'JSON'
  };

  static FeatureValueType? fromJson(dynamic data) =>
      data == null ? null : fromMap[data];

  dynamic toJson() => toMap[this];

  static List<FeatureValueType> listFromJson(List<dynamic>? json) =>
      json == null
          ? <FeatureValueType>[]
          : json.map((value) => fromJson(value)).toList().fromNull();

  static FeatureValueType copyWith(FeatureValueType instance) => instance;

  static Map<String, FeatureValueType> mapFromJson(Map<String, dynamic>? json) {
    final map = <String, FeatureValueType>{};
    if (json != null && json.isNotEmpty) {
      json.forEach((String key, dynamic value) {
        final val = fromJson(value);
        if (val != null) {
          map[key] = val;
        }
      });
    }
    return map;
  }
}
