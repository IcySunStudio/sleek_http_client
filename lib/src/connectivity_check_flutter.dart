// Flutter implementation — uses connectivity_plus.
import 'package:connectivity_plus/connectivity_plus.dart';

Future<bool> defaultIsOnline() async {
  final result = await Connectivity().checkConnectivity();
  return !result.contains(ConnectivityResult.none);
}

