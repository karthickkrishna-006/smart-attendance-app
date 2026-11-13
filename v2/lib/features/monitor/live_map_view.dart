import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
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

/// A worker on the map: initials avatar in the status colour, optional trail.
class MapPin {
  const MapPin({
    required this.id,
    required this.at,
    required this.initials,
    required this.title,
    required this.snippet,
    required this.color,
    this.selected = false,
    this.trail = const [],
  });
  final String id;
  final GeoPoint2 at;
  final String initials;
  final String title;
  final String snippet;
  final Color color;
  final bool selected;
  final List<GeoPoint2> trail;
}

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.characters.take(2).toString().toUpperCase();
  return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
}

/// Lets the screen move the camera ("show this worker", "fit everyone").
class LiveMapController {
  void Function(GeoPoint2 at, double zoom)? _move;
  void Function(List<GeoPoint2> points)? _fit;
  void moveTo(GeoPoint2 at, {double zoom = 17}) => _move?.call(at, zoom);
  void fitAll(List<GeoPoint2> points) {
    if (points.isEmpty) return;
    if (points.length == 1) return moveTo(points.first, zoom: 16);
    _fit?.call(points);
  }
}

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

/// Draws an initials pin (circle with a white ring and a point) as PNG bytes.
Future<Uint8List> _pinPng(String initials, Color color, bool selected) async {
  const w = 96.0, h = 116.0, r = 38.0;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  const cx = w / 2, cy = r + 6;
  if (selected) c.drawCircle(const Offset(cx, cy), r + 6, Paint()..color = color.withValues(alpha: 0.3));
  final point = Path()
    ..moveTo(cx - 14, cy + r - 8)
    ..lineTo(cx, h - 4)
    ..lineTo(cx + 14, cy + r - 8)
    ..close();
  c.drawPath(point, Paint()..color = color);
  c.drawCircle(const Offset(cx, cy), r, Paint()..color = Colors.white);
  c.drawCircle(const Offset(cx, cy), r - 5, Paint()..color = color);
  final tp = TextPainter(
    text: TextSpan(text: initials, style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w700)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(c, Offset(cx - tp.width / 2, cy - tp.height / 2));
  final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
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
  final _icons = <String, gm.BitmapDescriptor>{};
  final _pending = <String>{};

  gm.LatLng _ll(GeoPoint2 p) => gm.LatLng(p.lat, p.lng);
  String _iconKey(MapPin p) => '${p.initials}|${p.color.hashCode}|${p.selected}';

  @override
  void initState() {
    super.initState();
    widget.view.controller._move = (at, zoom) => _c?.animateCamera(gm.CameraUpdate.newLatLngZoom(_ll(at), zoom));
    widget.view.controller._fit = (pts) {
      final lats = pts.map((p) => p.lat), lngs = pts.map((p) => p.lng);
      _c?.animateCamera(gm.CameraUpdate.newLatLngBounds(
        gm.LatLngBounds(
          southwest: gm.LatLng(lats.reduce((a, b) => a < b ? a : b), lngs.reduce((a, b) => a < b ? a : b)),
          northeast: gm.LatLng(lats.reduce((a, b) => a > b ? a : b), lngs.reduce((a, b) => a > b ? a : b)),
        ),
        60,
      ));
    };
  }

  /// Avatar pins are drawn once per (initials, colour, selected) and cached.
  void _ensureIcons() {
    for (final p in widget.view.pins) {
      final k = _iconKey(p);
      if (_icons.containsKey(k) || _pending.contains(k)) continue;
      _pending.add(k);
      _pinPng(p.initials, p.color, p.selected).then((png) {
        if (!mounted) return;
        setState(() {
          _icons[k] = gm.BitmapDescriptor.bytes(png, width: 40);
          _pending.remove(k);
        });
      });
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    _ensureIcons();
    return Stack(children: [
      gm.GoogleMap(
        initialCameraPosition: gm.CameraPosition(target: _ll(v.center), zoom: 15),
        mapType: _type,
        onMapCreated: (c) => _c = c,
        // Pan and zoom the map even inside a scrolling screen.
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
        myLocationButtonEnabled: false,
        zoomControlsEnabled: true,
        mapToolbarEnabled: false,
        compassEnabled: true,
        polygons: {
          for (final a in v.areas.where((a) => a.ring.length >= 3))
            gm.Polygon(polygonId: gm.PolygonId(a.id), points: [for (final p in a.ring) _ll(p)], strokeColor: a.stroke, strokeWidth: 3, fillColor: a.fill),
        },
        circles: {
          for (final a in v.areas.where((a) => a.center != null && a.radiusM != null))
            gm.Circle(circleId: gm.CircleId(a.id), center: _ll(a.center!), radius: a.radiusM!, strokeColor: a.stroke, strokeWidth: 3, fillColor: a.fill),
          for (final d in v.dots)
            gm.Circle(circleId: gm.CircleId('dot-${d.id}'), center: _ll(d.at), radius: d.radiusM, strokeColor: d.stroke, strokeWidth: 2, fillColor: d.fill),
        },
        polylines: {
          for (final p in v.pins.where((p) => p.trail.length > 1))
            gm.Polyline(polylineId: gm.PolylineId('trail-${p.id}'), points: [for (final q in p.trail) _ll(q)], color: p.color, width: 4),
          if (v.route.length > 1)
            gm.Polyline(polylineId: const gm.PolylineId('route'), points: [for (final p in v.route) _ll(p)], color: AppColors.indigo, width: 6),
        },
        markers: {
          for (final p in v.pins)
            gm.Marker(
              markerId: gm.MarkerId(p.id),
              position: _ll(p.at),
              icon: _icons[_iconKey(p)] ?? gm.BitmapDescriptor.defaultMarker,
              anchor: const Offset(0.5, 1),
              zIndex: p.selected ? 2 : 1,
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
    widget.view.controller._fit = (pts) => _c.fitCamera(
          fm.CameraFit.coordinates(coordinates: [for (final p in pts) _ll(p)], padding: const EdgeInsets.all(60)),
        );
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
          fm.PolylineLayer(polylines: [
            for (final p in v.pins.where((p) => p.trail.length > 1))
              fm.Polyline(points: [for (final q in p.trail) _ll(q)], strokeWidth: 3.5, color: p.color),
            if (v.route.length > 1) fm.Polyline(points: [for (final p in v.route) _ll(p)], strokeWidth: 5, color: AppColors.indigo),
          ]),
          fm.MarkerLayer(markers: [
            for (final p in v.pins)
              fm.Marker(
                point: _ll(p.at),
                width: 110,
                height: 74,
                alignment: Alignment.topCenter,
                child: GestureDetector(
                  onTap: () => v.onPinTap(p.id),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: p.selected ? 44 : 38,
                      height: p.selected ? 44 : 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: p.color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [BoxShadow(color: p.color.withValues(alpha: p.selected ? 0.6 : 0.35), blurRadius: p.selected ? 14 : 6, spreadRadius: p.selected ? 4 : 1)],
                      ),
                      child: Text(p.initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(4)),
                      child: Text(p.title.split(' ').first, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppColors.ink)),
                    ),
                  ]),
                ),
              ),
          ]),
        ],
      ),
      const Positioned(right: 6, bottom: 4, child: Text('© OpenStreetMap', style: TextStyle(fontSize: 10, color: AppColors.muted))),
    ]);
  }
}
