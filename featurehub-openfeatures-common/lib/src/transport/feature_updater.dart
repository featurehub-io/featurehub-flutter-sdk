import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'edge_request.dart';

/// A change to a feature's value or lock, sent by [FeatureHubFeatureUpdater].
class FeatureUpdate {
  /// The new value (null to make the feature not set, with [updateValue]).
  /// A JSON feature's value may be given as a map or list, or as its JSON
  /// text; it is sent as its JSON text.
  final Object? value;

  /// True to change the value: implied by a non-null [value], so only needed
  /// to clear it.
  final bool updateValue;

  /// True to lock, false to unlock, null to leave the lock as it is.
  final bool? lock;

  /// A change of any combination: prefer [FeatureUpdate.value],
  /// [FeatureUpdate.clear] and [FeatureUpdate.lock].
  const FeatureUpdate({this.value, bool updateValue = false, this.lock})
    : updateValue = updateValue || value != null;

  /// Sets the value to [value] (null makes it not set). With [lock] false it
  /// also unlocks the feature, which a locked feature's value change needs.
  const FeatureUpdate.value(this.value, {this.lock}) : updateValue = true;

  /// Makes the feature not set (not possible for a flag). With [lock] false
  /// it also unlocks it.
  const FeatureUpdate.clear({this.lock}) : value = null, updateValue = true;

  /// Locks ([locked] true) or unlocks the feature, leaving its value.
  const FeatureUpdate.lock(bool locked)
    : value = null,
      updateValue = false,
      lock = locked;

  /// The `FeatureStateUpdate` body: the value (a JSON feature's map or list
  /// as its JSON text), `updateValue` only to clear it, and the lock.
  Map<String, Object?> toJson() {
    final value = this.value;
    return {
      if (value != null)
        'value': value is Map || value is List ? jsonEncode(value) : value,
      if (value == null && updateValue) 'updateValue': true,
      'lock': ?lock,
    };
  }

  @override
  String toString() => 'FeatureUpdate(${toJson()})';
}

/// What FeatureHub Edge answered to a [FeatureUpdate].
enum FeatureUpdateOutcome {
  /// 200 or 201: accepted and published. It reaches the clients (this
  /// process's included) later, through their polling or streaming.
  applied,

  /// 202: neither the value nor the lock would change.
  unchanged,

  /// 400: nothing to do, or a value that is not valid for the feature's
  /// type.
  invalid,

  /// 403: the API key's service account lacks the permission the change
  /// needs (CHANGE_VALUE, LOCK or UNLOCK).
  forbidden,

  /// 404: the API key, the environment or the feature does not exist.
  notFound,

  /// 412: a locked feature's value changed without unlocking it, or a flag's
  /// value cleared.
  notPossible,

  /// 503: updates are blocked for now; see [FeatureUpdateResult.retryAfter].
  unavailable,

  /// Any other status, a network error or a timeout.
  failed,
}

/// The result of a [FeatureHubFeatureUpdater.update].
class FeatureUpdateResult {
  final FeatureUpdateOutcome outcome;

  /// The HTTP status, or null for a network error or timeout.
  final int? statusCode;

  /// For [FeatureUpdateOutcome.unavailable], when to try again, if Edge said
  /// (its `Retry-After`, in seconds).
  final Duration? retryAfter;

  /// The network error or timeout, for [FeatureUpdateOutcome.failed] without
  /// a status.
  final Object? error;

  const FeatureUpdateResult(
    this.outcome, {
    this.statusCode,
    this.retryAfter,
    this.error,
  });

  /// The outcome of a response with [statusCode].
  factory FeatureUpdateResult.fromStatus(
    int statusCode, {
    Duration? retryAfter,
  }) => FeatureUpdateResult(
    switch (statusCode) {
      200 || 201 => FeatureUpdateOutcome.applied,
      202 => FeatureUpdateOutcome.unchanged,
      400 => FeatureUpdateOutcome.invalid,
      403 => FeatureUpdateOutcome.forbidden,
      404 => FeatureUpdateOutcome.notFound,
      412 => FeatureUpdateOutcome.notPossible,
      503 => FeatureUpdateOutcome.unavailable,
      _ => FeatureUpdateOutcome.failed,
    },
    statusCode: statusCode,
    retryAfter: statusCode == 503 ? retryAfter : null,
  );

  /// True if Edge accepted the update: [FeatureUpdateOutcome.applied] or
  /// [FeatureUpdateOutcome.unchanged].
  bool get success =>
      outcome == FeatureUpdateOutcome.applied ||
      outcome == FeatureUpdateOutcome.unchanged;

  @override
  String toString() =>
      'FeatureUpdateResult(${outcome.name}'
      '${statusCode == null ? '' : ', $statusCode'}'
      '${retryAfter == null ? '' : ', retry after $retryAfter'}'
      '${error == null ? '' : ', $error'})';
}

/// Changes features' values and locks in a FeatureHub environment through
/// Edge (`PUT <host>/features/<apiKey>/<featureKey>`), with the
/// environment's API key: for tests and test tools, not for resolving
/// flags.
///
/// The key's service account needs CHANGE_VALUE to change a value, and LOCK
/// or UNLOCK to change the lock. Edge accepts an update and publishes it:
/// the change reaches every client later, through its polling or streaming,
/// and this changes nothing locally. Updates are not retried: whether to try
/// again (after a [FeatureUpdateOutcome.unavailable]'s
/// [FeatureUpdateResult.retryAfter], or when a change raced another and was
/// lost) is the caller's choice.
///
/// It works in browsers and on `dart:io` alike, with a client- or a
/// server-evaluated key.
class FeatureHubFeatureUpdater {
  final EdgeHost _host;

  /// The environment's API key.
  final String apiKey;

  /// Headers sent with every update, for example for a proxy or gateway.
  final Map<String, String> headers;

  /// How long an update may take before it is [FeatureUpdateOutcome.failed].
  final Duration requestTimeout;

  final Dio _dio;
  final bool _ownDio;

  /// [host] is FeatureHub Edge's URL. [dio] makes the requests (by default
  /// one is created, and closed by [close]).
  FeatureHubFeatureUpdater({
    required String host,
    required String apiKey,
    this.headers = const {},
    this.requestTimeout = const Duration(seconds: 3),
    Dio? dio,
  }) : _host = EdgeHost(_required(host, 'host')),
       apiKey = _required(apiKey, 'apiKey'),
       _dio = dio ?? Dio(),
       _ownDio = dio == null;

  static String _required(String value, String name) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(value, name, 'is empty');
    return trimmed;
  }

  /// The URL an update of [featureKey] is sent to.
  String urlFor(String featureKey) {
    final base = _host.base.endsWith('/') ? _host.base : '${_host.base}/';
    final query = _host.query
        .map(
          (p) =>
              '${Uri.encodeQueryComponent(p.key)}='
              '${Uri.encodeQueryComponent(p.value)}',
        )
        .join('&');
    return '${base}features/$apiKey/${Uri.encodeComponent(featureKey)}'
        '${query.isEmpty ? '' : '?$query'}';
  }

  /// Sends [update] for [featureKey], and returns what Edge answered. It
  /// never throws for a status, a network error or a timeout.
  Future<FeatureUpdateResult> update(
    String featureKey,
    FeatureUpdate update,
  ) async {
    try {
      final response = await _dio
          .put<String>(
            urlFor(featureKey),
            data: jsonEncode(update.toJson()),
            options: Options(
              headers: {...headers, 'content-type': 'application/json'},
              responseType: ResponseType.plain,
              // every status is an outcome, not an exception
              validateStatus: (_) => true,
            ),
          )
          .timeout(requestTimeout);
      final status = response.statusCode;
      if (status == null) {
        return const FeatureUpdateResult(FeatureUpdateOutcome.failed);
      }
      return FeatureUpdateResult.fromStatus(
        status,
        retryAfter: _retryAfter(response.headers.value('retry-after')),
      );
    } catch (e) {
      return FeatureUpdateResult(FeatureUpdateOutcome.failed, error: e);
    }
  }

  static Duration? _retryAfter(String? value) {
    final seconds = int.tryParse(value?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  /// Closes the HTTP client, if it was created here.
  void close() {
    if (_ownDio) _dio.close();
  }
}
