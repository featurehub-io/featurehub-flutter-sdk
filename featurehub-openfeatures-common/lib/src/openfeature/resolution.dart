import 'dart:convert';

import 'package:featurehub_client_api/api.dart';

import '../evaluated_feature.dart';

/// The OpenFeature resolution types.
enum FeatureKind {
  boolean(FeatureValueType.BOOLEAN),
  string(FeatureValueType.STRING),
  integer(FeatureValueType.NUMBER),
  double(FeatureValueType.NUMBER),
  object(FeatureValueType.JSON);

  /// The FeatureHub feature type a flag must have to be resolved as this kind.
  final FeatureValueType featureType;

  const FeatureKind(this.featureType);
}

/// OpenFeature resolution reasons used by the FeatureHub providers.
abstract final class ResolutionReason {
  static const targetingMatch = 'TARGETING_MATCH';

  /// A percentage rollout strategy matched (evaluated locally).
  static const split = 'SPLIT';
  static const static_ = 'STATIC';
  static const default_ = 'DEFAULT';

  /// The feature has no value set: the code default is returned.
  static const disabled = 'DISABLED';
  static const error = 'ERROR';

  /// The value is the previous evaluation context's: a context change is in
  /// progress, and the new context's features have not arrived yet.
  static const stale = 'STALE';
}

/// OpenFeature error codes used by the FeatureHub providers. Each provider
/// maps these onto its OpenFeature SDK's error code type.
enum ResolutionErrorCode {
  providerNotReady,
  providerFatal,
  flagNotFound,
  typeMismatch,
  parseError,
  invalidContext,
  general,
}

/// An OpenFeature resolution, independent of the OpenFeature SDK in use.
class FeatureHubResolution<T> {
  final T value;
  final String reason;
  final ResolutionErrorCode? errorCode;
  final String? errorMessage;

  /// The id of the FeatureHub rollout strategy that matched, if any.
  final String? variant;

  /// `featureVersion` (int) and `featureType` (the FeatureHub type name).
  final Map<String, Object> flagMetadata;

  const FeatureHubResolution({
    required this.value,
    required this.reason,
    this.errorCode,
    this.errorMessage,
    this.variant,
    this.flagMetadata = const {},
  });

  /// An error resolution returning [defaultValue].
  const FeatureHubResolution.error(
    T defaultValue,
    ResolutionErrorCode code,
    String message, {
    Map<String, Object> flagMetadata = const {},
  }) : this(
         value: defaultValue,
         reason: ResolutionReason.error,
         errorCode: code,
         errorMessage: message,
         flagMetadata: flagMetadata,
       );

  bool get isError => errorCode != null;

  /// This resolution with the reason [ResolutionReason.stale], unless it is
  /// an error: the value was resolved from the previous context's features,
  /// during a context change.
  FeatureHubResolution<T> asStale() => isError
      ? this
      : FeatureHubResolution(
          value: value,
          reason: ResolutionReason.stale,
          variant: variant,
          flagMetadata: flagMetadata,
        );

  @override
  String toString() =>
      'FeatureHubResolution($value, $reason'
      '${errorCode == null ? '' : ', $errorCode: $errorMessage'}'
      '${variant == null ? '' : ', variant $variant'})';
}

FeatureHubResolution<T> notReadyResolution<T>(T defaultValue) =>
    FeatureHubResolution.error(
      defaultValue,
      ResolutionErrorCode.providerNotReady,
      'FeatureHub provider has not completed initialization.',
    );

/// A resolution while a context change has not delivered the new context's
/// features within the provider's wait: the previous context's features are
/// not used for it.
FeatureHubResolution<T> contextPendingResolution<T>(T defaultValue) =>
    FeatureHubResolution.error(
      defaultValue,
      ResolutionErrorCode.providerNotReady,
      "FeatureHub has not delivered the features for the new evaluation "
      "context yet.",
    );

/// A resolution for a context whose features can no longer be fetched (the
/// source stopped for good with another context's features).
FeatureHubResolution<T> contextUnavailableResolution<T>(T defaultValue) =>
    FeatureHubResolution.error(
      defaultValue,
      ResolutionErrorCode.providerNotReady,
      "FeatureHub has stopped, so the features for this evaluation context "
      "cannot be fetched.",
    );

FeatureHubResolution<T> fatalResolution<T>(T defaultValue) =>
    FeatureHubResolution.error(
      defaultValue,
      ResolutionErrorCode.providerFatal,
      'FeatureHub rejected this API key, or the environment no longer exists.',
    );

FeatureHubResolution<T> invalidContextResolution<T>(
  T defaultValue,
  Object error,
) => FeatureHubResolution.error(
  defaultValue,
  ResolutionErrorCode.invalidContext,
  error is Exception ? error.toString() : '$error',
);

FeatureHubResolution<T> generalErrorResolution<T>(
  T defaultValue,
  Object error,
) => FeatureHubResolution.error(
  defaultValue,
  ResolutionErrorCode.general,
  '$error',
);

/// The feature's properties (`FeatureState.fp`) if it has any, merged with
/// its version and type; `featureVersion` and `featureType` replace any
/// property of the same name.
Map<String, Object> _flagMetadata(EvaluatedFeature evaluation) => {
  ...?evaluation.featureState?.fp,
  if (evaluation.version != null && evaluation.version! >= 0)
    'featureVersion': evaluation.version!,
  if (evaluation.type != null) 'featureType': evaluation.type!.name!,
};

/// Applies OpenFeature resolution semantics to a FeatureHub evaluation: not
/// found, type mismatch, value-less features (the code default, `DISABLED`),
/// JSON parsing, and `TARGETING_MATCH` (with the matched strategy as the
/// variant; `SPLIT` for a percentage rollout matched locally) or `STATIC`.
///
/// This is the single implementation shared by the server and client
/// providers, matching the Go SDK's OpenFeature provider.
FeatureHubResolution<T> resolveFromEvaluation<T>(
  String flagKey,
  FeatureKind kind,
  T defaultValue,
  EvaluatedFeature evaluation,
) {
  if (!evaluation.exists) {
    return FeatureHubResolution.error(
      defaultValue,
      ResolutionErrorCode.flagNotFound,
      "Flag '$flagKey' was not found in this FeatureHub environment.",
    );
  }

  final metadata = _flagMetadata(evaluation);
  final featureType = evaluation.type;

  FeatureHubResolution<T> mismatch(String why) => FeatureHubResolution.error(
    defaultValue,
    ResolutionErrorCode.typeMismatch,
    "Flag '$flagKey' $why and cannot be resolved as ${kind.name}.",
    flagMetadata: metadata,
  );

  if (featureType != null && featureType != kind.featureType) {
    return mismatch('is of type ${featureType.name}');
  }

  final raw = evaluation.value;
  if (raw == null) {
    // no value set (by the feature, or the strategy or interceptor that
    // supplied it): the code default, as the Go SDK does
    return FeatureHubResolution(
      value: defaultValue,
      reason: ResolutionReason.disabled,
      variant: evaluation.strategyId,
      flagMetadata: metadata,
    );
  }

  final Object value;
  switch (kind) {
    case FeatureKind.boolean:
      if (raw is bool) {
        value = raw;
      } else if (raw == 'true' || raw == 'false') {
        // interceptors supply strings
        value = raw == 'true';
      } else {
        return mismatch('has the value $raw');
      }
    case FeatureKind.string:
      value = raw is String ? raw : '$raw';
    case FeatureKind.integer:
      final n = raw is num ? raw : num.tryParse('$raw');
      if (n == null || n != n.truncateToDouble()) {
        return mismatch('has the value $raw, which is not an integer,');
      }
      value = n.toInt();
    case FeatureKind.double:
      final n = raw is num ? raw : num.tryParse('$raw');
      if (n == null) return mismatch('has the value $raw');
      value = n.toDouble();
    case FeatureKind.object:
      final Object? decoded;
      try {
        decoded = raw is String ? jsonDecode(raw) : raw;
      } on FormatException {
        return FeatureHubResolution.error(
          defaultValue,
          ResolutionErrorCode.parseError,
          "Flag '$flagKey' contains invalid JSON.",
          flagMetadata: metadata,
        );
      }
      if (decoded is! Map) return mismatch('is not a JSON object');
      value = Map<String, Object?>.from(decoded);
  }

  if (value is! T) {
    return mismatch('has a ${value.runtimeType} value');
  }

  final strategyId = evaluation.strategyId;
  return FeatureHubResolution(
    value: value as T,
    reason: strategyId == null
        ? ResolutionReason.static_
        : evaluation.split
        ? ResolutionReason.split
        : ResolutionReason.targetingMatch,
    variant: strategyId,
    flagMetadata: metadata,
  );
}
