import 'package:featurehub_client_api/api.dart';


abstract class FeatureStateHolder {
  bool get exists;
  bool? get flag;
  String? get string;
  num? get number;
  dynamic get json;
  dynamic get value;
  bool get set;
  bool get enabled;
  bool get hasValue;

  String? get key;
  FeatureValueType? get type;

  int? get version;

  Stream<FeatureStateHolder> get featureUpdateStream;

  FeatureStateHolder copy();
}

enum Readiness { NotReady, Ready, Failed }

class InterceptorValue {
  final bool matched;
  final dynamic val;

  InterceptorValue(this.matched, this.val);

  @override
  cast(FeatureValueType expectedType) {
    // TODO: implement cast
    throw UnimplementedError();
  }
}

abstract class FeatureValueInterceptor {
  InterceptorValue matches(String key);
  bool get allowLockedOverride;
}

