import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Result of processing a captured selfie.
class FaceCapture {
  final bool ok;
  final String message;
  final List<double>? embedding;
  final String? thumbnail; // base64 JPEG of the cropped face (96 px)
  final double? quality;
  FaceCapture.fail(this.message)
      : ok = false,
        embedding = null,
        thumbnail = null,
        quality = null;
  FaceCapture.success(this.embedding, this.thumbnail, this.quality)
      : ok = true,
        message = 'Face captured';
}

/// Outcome contract (Product Report §5.3): worker_id, verified, similarity,
/// status, message, timestamp.
class FaceVerification {
  final String status; // verified | failed | unavailable | not_enrolled | no_face
  final bool verified;
  final double? similarity;
  final double threshold;
  final String message;
  final DateTime timestamp;
  final String? thumbnail;
  FaceVerification(this.status, this.verified, this.similarity, this.threshold, this.message, {this.thumbnail})
      : timestamp = DateTime.now();

  Map<String, dynamic> toMap(String workerId) => {
        'worker_id': workerId,
        'verified': verified,
        'similarity': similarity,
        'threshold': threshold,
        'status': status,
        'message': message,
        'timestamp': timestamp.toIso8601String(),
        'model': FaceService.modelName,
      };
}

/// On-device AI face verification:
///  1. Google ML Kit detects the face (exactly one, eyes open, frontal).
///  2. The face is cropped, aligned to the model input and passed through a
///     MobileFaceNet TensorFlow Lite model, producing an embedding vector.
///  3. Cosine similarity against the worker's enrolled reference embedding is
///     compared with the configurable threshold.
/// Nothing is reported as verified unless this pipeline actually ran.
class FaceService {
  static const modelAsset = 'assets/models/mobilefacenet.tflite';
  static const modelName = 'MobileFaceNet (TFLite) + ML Kit detector';
  static Interpreter? _interp;
  static String? loadError;
  static List<int> _inShape = const [];
  static List<int> _outShape = const [];

  static Future<bool> ensureLoaded() async {
    if (_interp != null) return true;
    try {
      final opts = InterpreterOptions()..threads = 2;
      _interp = await Interpreter.fromAsset(modelAsset, options: opts);
      _inShape = _interp!.getInputTensor(0).shape;
      _outShape = _interp!.getOutputTensor(0).shape;
      loadError = null;
      return true;
    } catch (e) {
      loadError = 'Face model could not be loaded: $e';
      _interp = null;
      return false;
    }
  }

  static String get modelInfo => _interp == null ? 'not loaded' : 'input $_inShape → output $_outShape';

  static Future<FaceCapture> process(String path) async {
    final detector = FaceDetector(
      options: FaceDetectorOptions(
        enableClassification: true,
        enableLandmarks: false,
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15,
      ),
    );
    try {
      final faces = await detector.processImage(InputImage.fromFilePath(path));
      if (faces.isEmpty) return FaceCapture.fail('No face detected. Hold the phone at eye level in good light.');
      if (faces.length > 1) return FaceCapture.fail('More than one face detected. Only the worker should be in the frame.');
      final f = faces.first;
      final yaw = (f.headEulerAngleY ?? 0).abs();
      final roll = (f.headEulerAngleZ ?? 0).abs();
      if (yaw > 25 || roll > 25) return FaceCapture.fail('Please look straight at the camera.');
      final le = f.leftEyeOpenProbability, re = f.rightEyeOpenProbability;
      if (le != null && re != null && le < 0.25 && re < 0.25) {
        return FaceCapture.fail('Eyes appear closed. Please keep your eyes open.');
      }

      if (!await ensureLoaded()) return FaceCapture.fail(loadError ?? 'Face model unavailable');

      final bytes = await File(path).readAsBytes();
      var image = img.decodeImage(bytes);
      if (image == null) return FaceCapture.fail('Could not read the captured image.');
      image = img.bakeOrientation(image);

      final crop = _cropFace(image, f.boundingBox);
      final h = _inShape.length == 4 ? _inShape[1] : 112;
      final w = _inShape.length == 4 ? _inShape[2] : 112;
      final resized = img.copyResize(crop, width: w, height: h, interpolation: img.Interpolation.cubic);
      final emb = _embed(resized);
      final thumb = base64Encode(img.encodeJpg(img.copyResize(crop, width: 96, height: 96), quality: 70));
      final quality = (f.boundingBox.width / image.width).clamp(0.0, 1.0);
      return FaceCapture.success(emb, thumb, quality);
    } catch (e) {
      return FaceCapture.fail('Face processing error: $e');
    } finally {
      await detector.close();
    }
  }

  static img.Image _cropFace(img.Image image, Rect box) {
    final m = 0.18;
    final size = math.max(box.width, box.height) * (1 + m * 2);
    final cx = box.center.dx, cy = box.center.dy;
    int x = (cx - size / 2).round(), y = (cy - size / 2).round(), s = size.round();
    x = x.clamp(0, image.width - 1);
    y = y.clamp(0, image.height - 1);
    s = math.min(s, math.min(image.width - x, image.height - y));
    return img.copyCrop(image, x: x, y: y, width: s, height: s);
  }

  static List<double> _embed(img.Image face) {
    final h = face.height, w = face.width;
    final batch = _inShape.isNotEmpty ? _inShape[0] : 1;
    final one = List.generate(
      h,
      (y) => List.generate(w, (x) {
        final p = face.getPixel(x, y);
        return [(p.r - 127.5) / 128.0, (p.g - 127.5) / 128.0, (p.b - 127.5) / 128.0];
      }),
    );
    final input = List.generate(batch, (_) => one);
    final outRows = _outShape.isNotEmpty ? _outShape[0] : 1;
    final outLen = _outShape.length > 1 ? _outShape[1] : 192;
    final output = List.generate(outRows, (_) => List<double>.filled(outLen, 0.0));
    _interp!.run(input, output);
    return _l2(output[0].map((e) => e.toDouble()).toList());
  }

  static List<double> _l2(List<double> v) {
    double s = 0;
    for (final x in v) {
      s += x * x;
    }
    s = math.sqrt(s);
    if (s == 0) return v;
    return v.map((e) => e / s).toList();
  }

  static double cosine(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0;
    double dot = 0, na = 0, nb = 0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// Full verification of a selfie against the enrolled reference.
  static Future<FaceVerification> verify(String path, List<double>? reference, double threshold) async {
    if (reference == null || reference.isEmpty) {
      return FaceVerification('not_enrolled', false, null, threshold,
          'No reference face enrolled for this worker. Enrol the face first.');
    }
    if (!await ensureLoaded()) {
      return FaceVerification('unavailable', false, null, threshold, loadError ?? 'Face verification service unavailable.');
    }
    final cap = await process(path);
    if (!cap.ok) return FaceVerification('no_face', false, null, threshold, cap.message);
    if (cap.embedding!.length != reference.length) {
      return FaceVerification('unavailable', false, null, threshold,
          'Enrolled reference was created with a different model. Please re-enrol the face.');
    }
    final sim = cosine(cap.embedding!, reference);
    final ok = sim >= threshold;
    return FaceVerification(
      ok ? 'verified' : 'failed',
      ok,
      sim,
      threshold,
      ok
          ? 'Face matched the enrolled reference (${(sim * 100).toStringAsFixed(1)}% similarity).'
          : 'Face did not match the enrolled reference (${(sim * 100).toStringAsFixed(1)}% < ${(threshold * 100).toStringAsFixed(0)}%).',
      thumbnail: cap.thumbnail,
    );
  }
}
