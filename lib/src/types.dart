/// Shared type aliases and utilities used by the HTTP client.
library;

/// A JSON object (map with string keys).
typedef JsonObject = Map<String, dynamic>;

/// A JSON list.
typedef JsonList = List<dynamic>;

/// Returns true if [T] is not set, `Null`, `void`, `Object?` or `dynamic`.
/// Used to detect when the caller does not care about the response body.
///
/// All four are distinct [Type] objects at runtime (e.g. `void == dynamic` is false), hence the explicit comparisons.
bool isTypeUndefined<T>() => T == _typeOf<Object?>() || T == Null || T == _typeOf<void>() || T == dynamic;

/// Returns the reified [Type] for [X], for types with no literal expression syntax (e.g. `void`, `Object?`).
Type _typeOf<X>() => X;

/// Extensions on [String].
extension StringHttpExtensions on String {
  /// Removes all newline characters from the string.
  String removeAllNewLines() => replaceAll('\n', '').replaceAll('\r', '');
}
