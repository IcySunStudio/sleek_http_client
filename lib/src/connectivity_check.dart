// Default (non-Flutter) stub — always reports online.
// Used when dart:ui is unavailable (e.g. pure-Dart CLI, unit tests).
// Override at the SleekHttpClient level via isOnlineChecker if needed.
Future<bool> defaultIsOnline() async => true;

