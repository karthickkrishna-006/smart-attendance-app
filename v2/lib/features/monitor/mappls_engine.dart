// Mappls (MapmyIndia) map engine: the app's main map.
//
// The Mappls licence files (<appId>.a.olf and <appId>.a.conf) are added to
// android/app at build time from GitHub secrets; see docs/MAPPLS-SETUP.md.
//
// API used (Mappls Flutter SDK docs, v2.0.x): MapplsMap(initialCameraPosition,
// onMapCreated, onMapClick), controller.addImage / addSymbol / addLine /
// addFill and their remove* counterparts, animateCamera with
// CameraUpdate.newLatLngZoom / newLatLngBounds / zoomIn / zoomOut.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:mappls_gl/mappls_gl.dart' as mp;

import '../../domain/geo.dart';
import 'live_map_view.dart';

const bool kMapplsAvailable = true;

Widget buildMapplsMap(LiveMapView view) => _MapplsMap(view: view);

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
mp.LatLng _ll(GeoPoint2 p) => mp.LatLng(p.lat, p.lng);

/// A circle of [radiusM] metres as a closed ring (Mappls fills are polygons).
List<GeoPoint2> _circle(GeoPoint2 c, double radiusM, {int n = 32}) {
  final dLat = radiusM / 111195.0;
  final dLng = radiusM / (111195.0 * math.cos(c.lat * math.pi / 180));
  return [for (var i = 0; i <= n; i++) GeoPoint2(c.lat + dLat * math.sin(2 * math.pi * i / n), c.lng + dLng * math.cos(2 * math.pi * i / n))];
}

Future<Uint8List> _dotPng() async {
  const s = 44.0;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawCircle(const Offset(s / 2, s / 2), s / 2 - 2, Paint()..color = Colors.white);
  c.drawCircle(const Offset(s / 2, s / 2), s / 2 - 7, Paint()..color = const Color(0xFF1A73E8));
  final img = await rec.endRecording().toImage(s.toInt(), s.toInt());
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

class _MapplsMap extends StatefulWidget {
  const _MapplsMap({required this.view});
  final LiveMapView view;
  @override
  State<_MapplsMap> createState() => _MapplsMapState();
}

class _MapplsMapState extends State<_MapplsMap> {
  mp.MapplsMapController? _c;
  bool _ready = false;
  bool _busy = false;
  bool _again = false;
  String _staticKey = '';
  final _staticFills = <mp.Fill>[];
  final _staticLines = <mp.Line>[];
  final _liveFills = <mp.Fill>[];
  final _liveLines = <mp.Line>[];
  final _liveSymbols = <mp.Symbol>[];
  final _images = <String>{};

  @override
  void initState() {
    super.initState();
    widget.view.controller.bind(
      move: (at, zoom) => _c?.animateCamera(mp.CameraUpdate.newLatLngZoom(_ll(at), zoom)),
      fit: (pts) {
        final lats = pts.map((p) => p.lat), lngs = pts.map((p) => p.lng);
        _c?.animateCamera(mp.CameraUpdate.newLatLngBounds(
          mp.LatLngBounds(
            southwest: mp.LatLng(lats.reduce(math.min), lngs.reduce(math.min)),
            northeast: mp.LatLng(lats.reduce(math.max), lngs.reduce(math.max)),
          ),
          left: 60,
          top: 60,
          right: 60,
          bottom: 60,
        ));
      },
      zoom: (zoomIn) => _c?.animateCamera(zoomIn ? mp.CameraUpdate.zoomIn() : mp.CameraUpdate.zoomOut()),
    );
  }

  @override
  void didUpdateWidget(covariant _MapplsMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready) unawaited(_sync());
  }

  /// The map style loads after the controller is created; annotations can
  /// only be added once it is ready, so retry a few times.
  Future<void> _onCreated(mp.MapplsMapController c) async {
    _c = c;
    for (var i = 0; i < 12 && !_ready && mounted; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      try {
        _staticKey = '';
        await _sync(throwErrors: true);
        _ready = true;
      } catch (_) {}
    }
  }

  void _onClick(math.Point<double> point, mp.LatLng at) {
    final v = widget.view;
    final here = GeoPoint2(at.latitude, at.longitude);
    MapPin? best;
    var bestD = 40.0;
    for (final p in v.pins) {
      final d = distanceM(here, p.at);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    if (best != null && v.onPinTap != null) {
      v.onPinTap!(best.id);
    } else {
      v.onMapTap?.call(here);
    }
  }

  Future<void> _sync({bool throwErrors = false}) async {
    final c = _c;
    if (c == null) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      final v = widget.view;
      // Boundaries and cleaning zones: redrawn only when they change.
      final key = [
        for (final a in v.areas) '${a.id}:${a.stroke.hashCode}:${a.fill.hashCode}:${a.ring.length}',
        for (final d in v.dots) '${d.id}:${d.fill.hashCode}',
      ].join('|');
      if (key != _staticKey) {
        for (final f in _staticFills) {
          await c.removeFill(f);
        }
        for (final l in _staticLines) {
          await c.removeLine(l);
        }
        _staticFills.clear();
        _staticLines.clear();
        for (final a in v.areas) {
          final ring = a.ring.length >= 3
              ? [...a.ring, a.ring.first]
              : (a.center != null && a.radiusM != null ? _circle(a.center!, a.radiusM!) : const <GeoPoint2>[]);
          if (ring.length < 4) continue;
          _staticFills.add(await c.addFill(mp.FillOptions(
            geometry: [ring.map(_ll).toList()],
            fillColor: _hex(a.fill),
            fillOpacity: a.fill.a,
            fillOutlineColor: _hex(a.stroke),
          )));
          _staticLines.add(await c.addLine(mp.LineOptions(geometry: ring.map(_ll).toList(), lineColor: _hex(a.stroke), lineWidth: 2.5)));
        }
        for (final d in v.dots) {
          _staticFills.add(await c.addFill(mp.FillOptions(
            geometry: [_circle(d.at, d.radiusM, n: 16).map(_ll).toList()],
            fillColor: _hex(d.fill),
            fillOpacity: d.fill.a,
            fillOutlineColor: _hex(d.stroke),
          )));
        }
        _staticKey = key;
      }

      // Workers, trails, the route and "me": redrawn on every update.
      for (final s in _liveSymbols) {
        await c.removeSymbol(s);
      }
      for (final l in _liveLines) {
        await c.removeLine(l);
      }
      for (final f in _liveFills) {
        await c.removeFill(f);
      }
      _liveSymbols.clear();
      _liveLines.clear();
      _liveFills.clear();
      for (final p in v.pins.where((p) => p.trail.length > 1)) {
        _liveLines.add(await c.addLine(mp.LineOptions(geometry: p.trail.map(_ll).toList(), lineColor: _hex(p.color), lineWidth: 3.5)));
      }
      if (v.route.length > 1) {
        _liveLines.add(await c.addLine(mp.LineOptions(geometry: v.route.map(_ll).toList(), lineColor: '#3949AB', lineWidth: 5)));
      }
      if (v.me != null) {
        if ((v.meAccuracyM ?? 0) > 0) {
          _liveFills.add(await c.addFill(mp.FillOptions(
            geometry: [_circle(v.me!, v.meAccuracyM!).map(_ll).toList()],
            fillColor: '#1A73E8',
            fillOpacity: 0.12,
            fillOutlineColor: '#1A73E8',
          )));
        }
        if (_images.add('me-dot')) await c.addImage('me-dot', await _dotPng());
        _liveSymbols.add(await c.addSymbol(mp.SymbolOptions(geometry: _ll(v.me!), iconImage: 'me-dot', iconSize: 0.5)));
      }
      for (final p in v.pins) {
        final img = 'pin-${p.initials}-${p.color.toARGB32()}-${p.selected}';
        if (_images.add(img)) await c.addImage(img, await pinPng(p.initials, p.color, p.selected));
        _liveSymbols.add(await c.addSymbol(mp.SymbolOptions(geometry: _ll(p.at), iconImage: img, iconSize: 0.42, iconAnchor: 'bottom')));
      }
    } catch (e) {
      if (throwErrors) rethrow;
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(_sync());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    return mp.MapplsMap(
      initialCameraPosition: mp.CameraPosition(target: _ll(v.center), zoom: v.zoom),
      onMapCreated: _onCreated,
      onMapClick: _onClick,
    );
  }
}
