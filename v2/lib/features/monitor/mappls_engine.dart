// Placeholder used by the normal build (Flutter 3.27, no Mappls SDK).
//
// The "Build v2 with Mappls (test)" workflow replaces this file with
// v2/mappls/mappls_engine.dart, adds the mappls_gl package and the app's
// Mappls licence files, and builds with --dart-define=MAPPLS=true.
import 'package:flutter/widgets.dart';

import 'live_map_view.dart';

const bool kMapplsAvailable = false;

Widget buildMapplsMap(LiveMapView view) => const SizedBox.shrink();
