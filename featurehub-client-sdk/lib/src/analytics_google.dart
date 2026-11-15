import 'dart:async';

import 'package:dio/dio.dart';
import 'package:featurehub_client_api/api.dart';
import 'package:logging/logging.dart';

import 'repository.dart';

final _log = Logger('FeatureHub_GAListener');
const _gaKey = '_gaev_value';

void insertGoogleAnalyticsEvValue(Map<String, Object> other, String gaValue) {
  other[_gaKey] = gaValue;
}

class GoogleAnalyticsListener {
  final ClientFeatureRepository _repository;
  final String ua;
  String? cid;
  StreamSubscription<AnalyticsEvent>? _analyticsListener;
  final GoogleAnalyticsApiClient _apiClient;

  GoogleAnalyticsListener(
    ClientFeatureRepository repository,
    this.ua, {
    this.cid,
    GoogleAnalyticsApiClient? apiClient,
  }) : _repository = repository,
       _apiClient = apiClient ?? GoogleAnalyticsDioApiClient() {
    _analyticsListener = _repository.analyticsEvent.listen(_analyticsPublisher);
  }

  void dispose() {
    _analyticsListener!.cancel();
    _analyticsListener = null;
  }

  void _analyticsPublisher(AnalyticsEvent event) {
    final finalCid = (event.other != null)
        ? (event.other!['cid']?.toString() ?? cid)
        : cid;

    if (finalCid == null) {
      _log.severe('Unable to log GA event as no CID provided.');
      return;
    }

    final ev = (event.other?.containsKey(_gaKey) ?? false)
        ? '&ev=${Uri.encodeQueryComponent(event.other![_gaKey] as String? ?? '')}'
        : '';

    var batchData = '';

    final baseForEachLine =
        'v=1&tid=$ua&cid=$finalCid&t=event&ec=FeatureHub%20Event&ea=${Uri.encodeQueryComponent(event.action)}$ev&el=';

    for (var f in event.features) {
      String? line;
      switch (f.type) {
        case null:
          break;
        case FeatureValueType.BOOLEAN:
          line = f.booleanValue! ? 'on' : 'off';
          break;
        case FeatureValueType.STRING:
          line = f.stringValue;
          break;
        case FeatureValueType.NUMBER:
          line = f.numberValue.toString();
          break;
        case FeatureValueType.JSON:
          line = null;
          break;
      }

      if (line != null) {
        batchData +=
            '$baseForEachLine${Uri.encodeQueryComponent('${f.key} : $line')}\n';
      }
    }

    if (batchData.isNotEmpty) {
      _apiClient.postAnalyticBatch(batchData);
    }
  }
}

abstract class GoogleAnalyticsApiClient {
  void postAnalyticBatch(String data);
}

class GoogleAnalyticsDioApiClient implements GoogleAnalyticsApiClient {
  final Dio _dio;

  GoogleAnalyticsDioApiClient() : _dio = Dio();

  @override
  void postAnalyticBatch(String data) {
    _dio
        .post(
          'https://www.google-analytics.com/batch',
          data: data,
          options: Options(contentType: 'application/x-www-form-urlencoded'),
        )
        .then<void>(
          (_) {},
          onError: (Object e, StackTrace s) {
            _log.severe('Failed to update GA', e, s);
          },
        );
  }
}
