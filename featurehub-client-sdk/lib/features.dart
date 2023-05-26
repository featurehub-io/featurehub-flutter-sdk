import 'package:featurehub_client_api/api.dart';
import 'package:meta/meta.dart';


abstract class FeatureStateHolder {
  /// true if the state exists in the repository for this feature
  bool get exists;

  /// if a boolean/flag, the value of the flag. Can be null if the flag does not exist (yet)
  bool? get flag;

  /// if a string, the string value
  String? get string;

  /// if a number, the value
  num? get number;

  /// a jsonDecoded version of the json
  dynamic get json;
  String get rawJson;

  /// the generic value of the feature, including using any feature interceptors
  dynamic get value;

  /// this feature actually has a value (i.e. it exists and isn't null) - uses interceptors
  bool get set;

  /// always returns true/false for a flag (true if exists, has value and value is true, otherwise false)
  bool get enabled;

  /// the key of the feature, always has a value as it is provided by the call even if the holder is empty of state
  String get key;

  /// the id of the feature if the feature has an id (empty if not)
  String get id;

  /// the type of the feature if the feature has a type (i.e. it has state)
  FeatureValueType? get type;

  /// the version (if has state) and -1 if no state or deleted.
  int get version;

  /// a stream of updates to the value of this as they come from the server. Value changes from interceptors or
  /// context are not sent via this mechanism. You should only use this in a Mobile/Web/Batch application where you have
  /// a constant context and a single user.
  Stream<FeatureStateHolder> get featureUpdateStream;

  /// makes a complete copy of the feature, removing parent links and makes a copy of the feature state if it is there.
  FeatureStateHolder copy();
}

enum Readiness { NotReady, Ready, Failed }

class InterceptorValue {
  final bool matched;
  final dynamic val;

  InterceptorValue(this.matched, this.val);

  cast(FeatureValueType expectedType) {
    // TODO: implement cast
    throw UnimplementedError();
  }
}

abstract class FeatureValueInterceptor {
  InterceptorValue matches(String key);
  bool get allowLockedOverride;
}

