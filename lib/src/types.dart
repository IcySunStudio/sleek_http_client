/// Shared type aliases and utilities used by the HTTP client.
library;

/// A JSON object (map with string keys).
typedef JsonObject = Map<String, dynamic>;

/// A JSON list.
typedef JsonList = List<dynamic>;

/// Returns true if [T] is unspecified (i.e. `dynamic`).
/// Used to detect when the caller does not care about the response body.
bool isTypeUndefined<T>() => T == dynamic;

/// Extensions on [String].
extension StringHttpExtensions on String {
  /// Removes all newline characters from the string.
  String removeAllNewLines() => replaceAll('\n', '').replaceAll('\r', '');
}
