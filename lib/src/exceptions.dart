import 'package:http/http.dart' as http;

/// Thrown when the device has no internet connectivity or a request times out.
class ConnectivityException implements Exception {
  const ConnectivityException(this.type);

  final ConnectivityExceptionType type;

  @override
  String toString() => 'ConnectivityException(${type.name})';
}

/// The kind of connectivity failure.
enum ConnectivityExceptionType {
  /// The device has no internet connection.
  noInternet,

  /// The request timed out.
  timeout,
}

/// Thrown when the server returns a non-2xx HTTP response.
class HttpResponseException implements Exception {
  const HttpResponseException(this.response, [this.jsonBody]);

  /// The raw HTTP response.
  final http.Response response;

  /// Parsed JSON body, if any.
  final dynamic jsonBody;

  /// HTTP status code of the response.
  int get statusCode => response.statusCode;

  @override
  String toString() => 'HttpResponseException(statusCode: $statusCode)';
}

/// Builder that creates a custom [HttpResponseException] from a response.
typedef HttpClientErrorBuilder = HttpResponseException Function(http.Response response, Map<String, dynamic>? responseJson);
