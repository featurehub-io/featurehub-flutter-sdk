
import 'features.dart';

/// register environment overrides using a dotenv file
/// by default this will always allow lock overrides to force the
/// client to honour the value stored in the environment regardless
/// of what the FeatureHub server is sending.
class DotEnvOverride implements FeatureValueInterceptor {
  final Map<String, String> env;
  final bool _allowLockedOverride;

  DotEnvOverride(this.env,
      {bool allowLockOverride = true}) : _allowLockedOverride = allowLockOverride;

  @override
  InterceptorValue matches(String key) {
    if (env.containsKey(key)) {
      return InterceptorValue(true, env[key]);
    }

    return InterceptorValue(false, null);
  }

  @override
  bool get allowLockedOverride => _allowLockedOverride;
}
