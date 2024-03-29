part of featurehub_client_api.api;

// This file is generated by https://github.com/dart-ogurets/dart-openapi-maven - you should not modify it
// log generation bugs on Github, as part of the license, you must not remove these headers from the Mustache templates.
// this project is maintained as part of FeatureHub - please consider sponsoring us at https://github.com/featurehub-io

class FeatureServiceApi {
  final FeatureServiceApiDelegate apiDelegate;
  FeatureServiceApi(ApiClient apiClient)
      : apiDelegate = FeatureServiceApiDelegate(apiClient);

  ///
  ///
  /// Requests all features for this sdkurl and disconnects
  Future<List<FeatureEnvironmentCollection>> getFeatureStates(
      List<String> apiKey,
      {Options? options,
      String? contextSha}) async {
    final response = await apiDelegate.getFeatureStates(apiKey,
        options: options, contextSha: contextSha);

    if (![200, 236, 400].contains(response.statusCode)) {
      throw ApiException(500,
          'Invalid response code ${response.statusCode} returned from API');
    }

    final __body = response.body;
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode,
          __body == null ? null : await decodeBodyBytes(__body));
    }

    if (__body == null) {
      throw ApiException(500, 'Received an empty body (not in a 204)');
    }

    return await apiDelegate.getFeatureStates_decode(__body);
  }

  ///
  ///
  /// Requests all features for this sdkurl and disconnects
  ///
  ///
  /// Updates the feature state if allowed.
  Future<void> setFeatureState(
      String sdkUrl, String featureKey, FeatureStateUpdate featureStateUpdate,
      {Options? options}) async {
    final response = await apiDelegate.setFeatureState(
      sdkUrl,
      featureKey,
      featureStateUpdate,
      options: options,
    );

    if (![200, 201, 202, 400, 403, 404, 412].contains(response.statusCode)) {
      throw ApiException(500,
          'Invalid response code ${response.statusCode} returned from API');
    }

    if (response.statusCode == 204) {
      return;
    }

    final __body = response.body;
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode,
          __body == null ? null : await decodeBodyBytes(__body));
    }

    throw ApiException(500, 'Invalid response received for 204 based API');
  }

  ///
  ///
  /// Updates the feature state if allowed.
}

class FeatureServiceApiDelegate {
  final ApiClient apiClient;

  FeatureServiceApiDelegate(this.apiClient);

  Future<ApiResponse> getFeatureStates(List<String> apiKey,
      {Options? options, String? contextSha}) async {
    // create path and map variables
    final __path = '/features/';

    // query params
    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{}
      ..addAll(options?.headers?.cast<String, String>() ?? {});
    if (!headerParams.containsKey('Accept')) {
      // we only want to accept this format as we can parse it
      headerParams['Accept'] = 'application/json';
    }

    queryParams.addAll(convertParametersForCollectionFormat(
        (p) => LocalApiClient.parameterToString(p)!,
        'multi',
        'apiKey',
        apiKey));
    if (contextSha != null) {
      queryParams.addAll(convertParametersForCollectionFormat(
          (p) => LocalApiClient.parameterToString(p)!,
          '',
          'contextSha',
          contextSha));
    }

    final authNames = <String>[];
    final opt = options ?? Options();

    final contentTypes = [];

    if (contentTypes.isNotEmpty && headerParams['Content-Type'] == null) {
      headerParams['Content-Type'] = contentTypes[0];
    }

    headerParams
        .removeWhere((key, value) => value.isEmpty); // remove empty headers
    opt.headers = headerParams;
    opt.method = 'GET';

    return await apiClient.invokeAPI(__path, queryParams, null, authNames, opt);
  }

  Future<List<FeatureEnvironmentCollection>> getFeatureStates_decode(
      Stream<List<int>> body) async {
    return (LocalApiClient.deserializeFromString(await utf8.decodeStream(body),
            'List<FeatureEnvironmentCollection>') as List)
        .map((item) => item as FeatureEnvironmentCollection)
        .toList();
  }

  Future<ApiResponse> setFeatureState(
      String sdkUrl, String featureKey, FeatureStateUpdate featureStateUpdate,
      {Options? options}) async {
    Object postBody = featureStateUpdate;

    // create path and map variables
    final __path = '/features/{sdkUrl}/{featureKey}'
        .replaceAll(
            '{' + 'sdkUrl' + '}', LocalApiClient.parameterToString(sdkUrl)!)
        .replaceAll('{' + 'featureKey' + '}',
            LocalApiClient.parameterToString(featureKey)!);

    // query params
    final queryParams = <QueryParam>[];
    final headerParams = <String, String>{}
      ..addAll(options?.headers?.cast<String, String>() ?? {});
    if (!headerParams.containsKey('Accept')) {
      // we only want to accept this format as we can parse it
      headerParams['Accept'] = 'application/json';
    }

    final authNames = <String>[];
    final opt = options ?? Options();

    final contentTypes = ['application/json'];

    if (contentTypes.isNotEmpty && headerParams['Content-Type'] == null) {
      headerParams['Content-Type'] = contentTypes[0];
    }
    postBody = LocalApiClient.serialize(postBody);

    headerParams
        .removeWhere((key, value) => value.isEmpty); // remove empty headers
    opt.headers = headerParams;
    opt.method = 'PUT';

    return await apiClient.invokeAPI(
        __path, queryParams, postBody, authNames, opt);
  }

  Future<void> setFeatureState_decode(Stream<List<int>> body) async {}
}
