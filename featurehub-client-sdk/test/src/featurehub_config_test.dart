//
//
// import 'dart:convert';
//
// import 'package:featurehub_client_sdk/featurehub.dart';
// import 'package:mocktail/mocktail.dart';
// import 'package:openapi_dart_common/openapi.dart';
// import 'package:test/test.dart';
//
// class _MockFeatureRepository extends Mock implements ClientFeatureRepository {
//   final ClientContext clientContext = ClientContext();
// }
//
// void main() {
//   late FeatureHubConfig config;
//   late _MockFeatureRepository repository;
//
//   setUp(() {
//     repository = _MockFeatureRepository();
//     config = new FeatureHubConfig('http://localhost',['123'], repository, timeout: 360);
//   });
//
//   test('We correctly decode cache-control headers', () {
//     final response = new ApiResponse(236, {'cache-control': ['blah, max-age=20, blah', 'blah']}, null);
//
//     config.checkForCacheControl(response);
//     expect(config.timeoutInSeconds, 20);
//   });
//
//   test('A 236 will stop updating', () async {
//     final data = Stream.value(utf8.encode('[{"id": "1"}]'));
//     final response = new ApiResponse(236, {'cache-control': ['blah, max-age=20, blah', 'blah']}, data);
//     final expireTime = config.whenNextPollAllowed;
//
//     expect(expireTime.isBefore(DateTime.now()), true);
//
//     await config.decodeResponse(response);
//
//     // the new whenNextPollAllowed should be 20 seconds after the last time we set it
//     expect(config.whenNextPollAllowed.isBefore(expireTime.add(Duration(seconds: 22))), true);
//     expect(config.isConnectionDead, true);
//   });
//
//   test('A 200 wont stop updating', () async {
//     final data = Stream.value(utf8.encode('[{"id": "1"}]'));
//     final response = new ApiResponse(200, {'cache-control': ['blah, max-age=20, blah', 'blah']}, data);
//     await config.decodeResponse(response);
//     expect(config.isConnectionDead, false);
//   });
// }