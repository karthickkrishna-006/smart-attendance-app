import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' as fm;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:latlong2/latlong.dart' as ll;

import '../../app/theme.dart';
import '../../domain/geo.dart';

/// Google Maps is used when the build has a Maps API key
/// (`--dart-define=GOOGLE_MAPS=true`, set by the CI workflow when the
/// MAPS_API_KEY secret exists); otherwise OpenStreetMap.
const bool kGoogleMaps = bool.fromEnvironment('GOOGLE_MAPS');

class MapArea {
  const MapArea({required this.id, this.ring = const [], this.center, this.radiusM, required this.stroke, required this.fill});
  final String id;
  final List<GeoPoint2> ring;
  final GeoPoint2? center;
  final double? radiusM;
  final Color stroke;
  final Color fill;
}

class MapDot {
  const MapDot({required this.id, required this.at, required this.radiusM, required this.fill, required this.stroke});
  final String id;
  final GeoPoint2 at;
  final double radiusM;
  final Color fill;
  final Color stroke;
}

enum MapPinTone { green, orange, faded, selected }

class MapPin {
  const MapPin({required this.id, required this.at, required this.title, required this.snippet, required this.tone});
  final String id;
  final GeoPoint2 at;
  final String title;
  final String snippet;
  final MapPinTone tone;
}

/// Lets the screen move the camera ("show this worker").
class LiveMapController {
  void Function(GeoPoint2 at, double zoom)? _move;
  void moveTo(GeoPoint2 at, {double zoom = 17}) => _move?.call(at, zoom);
}

Color pinColor(MapPinTone t) => switch (t) {
      MapPinTone.green => AppColors.success,
      MapPinTone.orange => AppColors.turmeric,
      MapPinTone.faded => const Color(0xFF7C9CBF),
      MapPinTone.selected => AppColors.indigo,
    };

class LiveMapView extends StatelessWidget {
  const LiveMapView({
    super.key,
    required this.center,
    required this.areas,
    required this.dots,
    required this.pins,
    required this.route,
    required this.controller,
    required this.onPinTap,
  });

  final GeoPoint2 center;
  final List<MapArea> areas;
  final List<MapDot> dots;
  final List<MapPin> pins;
  final List<GeoPoint2> route;
  final LiveMapController controller;
  final void Function(String id) onPinTap;

  @override
  Widget build(BuildContext context) => kGoogleMaps ? _GoogleMap(view: this) : _OsmMap(view: this);
}

// ---------------------------------------------------------------- Google
class _GoogleMap extends StatefulWidget {
  const _GoogleMap({required this.view});
  final LiveMapView view;
  @override
  State<_GoogleMap> createState() => _GoogleMapState();
}

class _GoogleMapState extends State<_GoogleMap> {
  gm.GoogleMapController? _c;
  gm.MapType _type = gm.MapType.normal;

  gm.LatLng _ll(GeoPoint2 p) => gm.LatLng(p.lat, p.lng);

  double _hue(MapPinTone t) => switch (t) {
        MapPinTone.green => gm.BitmapDescriptor.hueGreen,
        MapPinTone.orange => gm.BitmapDescriptor.hueOrange,
        MapPinTone.faded => gm.BitmapDescriptor.hueAzure,
        MapPinTone.selected => gm.BitmapDescriptor.hueViolet,
      };

  @override
  void initState() {
    super.initState();
    widget.view.controller._move = (at, zoom) => _c?.animateCamera(gm.CameraUpdate.newLatLngZoom(_ll(at), zoom));
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    return Stack(children: [
      gm.GoogleMap(
        initialCameraPosition: gm.CameraPosition(target: _ll(v.center), zoom: 15),
        mapType: _type,
        onMapCreated: (c) => _c = c,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: true,
        mapToolbarEnabled: false,
        compassEnabled: true,
        polygons: {
          for (final a in v.areas.where((a) => a.ring.length >= 3))
            gm.Polygon(
              polygonId: gm.PolygonId(a.id),
              points: [for (final p in a.ring) _ll(p)],
              strokeColor: a.stroke,
              strokeWidth: 3,
              fillColor: a.fill,
            ),
        },
        circles: {
          for (final a in v.areas.where((a) => a.center != null && a.radiusM != null))
            gm.Circle(circleId: gm.CircleId(a.id), center: _ll(a.center!), radius: a.radiusM!, strokeColor: a.stroke, strokeWidth: 3, fillColor: a.fill),
          for (final d in v.dots)
            gm.Circle(circleId: gm.CircleId('dot-${d.id}'), center: _ll(d.at), radius: d.radiusM, strokeColor: d.stroke, strokeWidth: 2, fillColor: d.fill),
        },
        polylines: {
          if (v.route.length > 1)
            gm.Polyline(polylineId: const gm.PolylineId('route'), points: [for (final p in v.route) _ll(p)], color: AppColors.indigo, width: 5),
        },
        markers: {
          for (final p in v.pins)
            gm.Marker(
              markerId: gm.MarkerId(p.id),
              position: _ll(p.at),
              icon: gm.BitmapDescriptor.defaultMarkerWithHue(_hue(p.tone)),
              alpha: p.tone == MapPinTone.faded ? 0.6 : 1,
              infoWindow: gm.InfoWindow(title: p.title, snippet: p.snippet),
              onTap: () => v.onPinTap(p.id),
            ),
        },
      ),
      Positioned(
        left: 10,
        top: 10,
        child: Material(
          color: Colors.white,
          elevation: 2,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _type = _type == gm.MapType.normal ? gm.MapType.hybrid : gm.MapType.normal),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_type == gm.MapType.normal ? Icons.satellite_alt : Icons.map_outlined, size: 18, color: AppColors.ink),
                const SizedBox(width: 6),
                Text(_type == gm.MapType.normal ? 'Satellite' : 'Map', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------- OpenStreetMap
class _OsmMap extends StatefulWidget {
  const _OsmMap({required this.view});
  final LiveMapView view;
  @override
  State<_OsmMap> createState() => _OsmMapState();
}

class _OsmMapState extends State<_OsmMap> {
  final _c = fm.MapController();
  ll.LatLng _ll(GeoPoint2 p) => ll.LatLng(p.lat, p.lng);

  @override
  void initState() {
    super.initState();
    widget.view.controller._move = (at, zoom) => _c.move(_ll(at), zoom);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    return Stack(children: [
      fm.FlutterMap(
        mapController: _c,
        options: fm.MapOptions(initialCenter: _ll(v.center), initialZoom: 15),
        children: [
          fm.TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'in.cit.smartattendance.v2'),
          fm.PolygonLayer(polygons: [
            for (final a in v.areas.where((a) => a.ring.length >= 3))
              fm.Polygon(points: [for (final p in a.ring) _ll(p)], color: a.fill, borderColor: a.stroke, borderStrokeWidth: 2.5),
          ]),
          fm.CircleLayer(circles: [
            for (final a in v.areas.where((a) => a.center != null && a.radiusM != null))
              fm.CircleMarker(point: _ll(a.center!), radius: a.radiusM!, useRadiusInMeter: true, color: a.fill, borderColor: a.stroke, borderStrokeWidth: 2.5),
            for (final d in v.dots)
              fm.CircleMarker(point: _ll(d.at), radius: d.radiusM, useRadiusInMeter: true, color: d.fill, borderColor: d.stroke, borderStrokeWidth: 1.5),
          ]),
          if (v.route.length > 1) fm.PolylineLayer(polylines: [fm.Polyline(points: [for (final p in v.route) _ll(p)], strokeWidth: 4, color: AppColors.indigo)]),
          fm.MarkerLayer(markers: [
            for (final p in v.pins)
              fm.Marker(
                point: _ll(p.at),
                width: 100,
                height: 60,
                child: GestureDetector(
                  onTap: () => v.onPinTap(p.id),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.person_pin_circle, size: 36, color: pinColor(p.tone)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(4)),
                      child: Text(p.title.split(' ').first, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppColors.ink)),
                    ),
                  ]),
                ),
              ),
          ]),
        ],
      ),
      const Positioned(
        right: 6,
        bottom: 4,
        child: Text('© OpenStreetMap', style: TextStyle(fontSize: 10, color: AppColors.muted)),
      ),
    ]);
  }
}
