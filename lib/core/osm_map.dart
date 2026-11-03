import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/models.dart';
import 'theme.dart';

/// OpenStreetMap base layer + attribution, shared by all map screens.
class OsmMap extends StatelessWidget {
  final MapController? controller;
  final LatLng center;
  final double zoom;
  final List<Widget> layers;
  final void Function(TapPosition, LatLng)? onTap;
  final bool interactive;
  const OsmMap({
    super.key,
    this.controller,
    required this.center,
    this.zoom = 15,
    this.layers = const [],
    this.onTap,
    this.interactive = true,
  });

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        maxZoom: 19,
        minZoom: 4,
        onTap: onTap,
        interactionOptions: InteractionOptions(
          flags: interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'in.cit.smartattendance',
          maxZoom: 19,
        ),
        ...layers,
        const RichAttributionWidget(
          alignment: AttributionAlignment.bottomLeft,
          attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
        ),
      ],
    );
  }
}

Polygon boundaryPolygon(Boundary b, {bool highlight = false}) {
  final c = b.synthetic ? AppColors.demo : AppColors.teal;
  return Polygon(
    points: b.points,
    color: c.withOpacity(highlight ? 0.22 : 0.12),
    borderColor: c,
    borderStrokeWidth: highlight ? 3 : 2,
    label: b.synthetic ? '${b.name}\n(SYNTHETIC)' : b.name,
    labelStyle: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 11),
  );
}

class MyLocationDot extends StatelessWidget {
  final Color color;
  const MyLocationDot({super.key, this.color = AppColors.info});
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 8)],
        ),
      );
}
