import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Result of processing a captured selfie.
class FaceCapture {
  final bool ok;
  final String message;
  final List<double>? embedding;
  final String? thumbnail; // base64 JPEG preview, kept in memory for on-screen display only – never stored
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
  static const modelName = 'MobileFaceNet TFLite (sha256 be4bc7cf…) + ML Kit detector';
  static const embeddingSize = 192;
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
      // Pinned model spec (third_party/mobilefacenet/MODEL_CARD.md):
      // input float32 [1,112,112,3], output float32 [1,192].
      if (_inShape.length != 4 || _inShape[0] != 1 || _inShape[1] != 112 || _inShape[2] != 112 || _inShape[3] != 3 ||
          _outShape.length != 2 || _outShape[0] != 1 || _outShape[1] != embeddingSize) {
        loadError = 'Unexpected face model tensors $_inShape → $_outShape (expected [1,112,112,3] → [1,$embeddingSize]).';
        _interp!.close();
        _interp = null;
        return false;
      }
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
      final resized = img.copyResize(crop, width: 112, height: 112, interpolation: img.Interpolation.cubic);
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
    // Pre-processing identical to the source project: (p - 128) / 128.
    final input = [
      List.generate(
        112,
        (y) => List.generate(112, (x) {
          final p = face.getPixel(x, y);
          return [(p.r - 128) / 128.0, (p.g - 128) / 128.0, (p.b - 128) / 128.0];
        }),
      ),
    ];
    final output = [List<double>.filled(embeddingSize, 0.0)];
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


/// Biometric template storage. Templates live in `face_templates/{uid}`,
/// separate from the user profile. Security rules let ONLY the owner read
/// their template; admins may delete it but cannot read it.
class FaceTemplates {
  static DocumentReference<Map<String, dynamic>> _ref(String uid) =>
      FirebaseFirestore.instance.collection('face_templates').doc(uid);

  /// Reads the signed-in user's own template (null if not enrolled).
  static Future<List<double>?> readOwn(String uid) async {
    final d = await _ref(uid).get();
    final e = d.data()?['embedding'];
    if (e is! List || e.length != FaceService.embeddingSize) return null;
    return e.map((v) => (v as num).toDouble()).toList();
  }

  /// Writes the template and flags the profile in one atomic batch.
  static Future<void> enrol({required String uid, required List<double> embedding, required String enrolledBy}) async {
    final fs = FirebaseFirestore.instance;
    final b = fs.batch();
    b.set(_ref(uid), {
      'embedding': embedding,
      'dims': FaceService.embeddingSize,
      'model': FaceService.modelName,
      'consent': true,
      'enrolledBy': enrolledBy,
      'enrolledAt': FieldValue.serverTimestamp(),
    });
    b.update(fs.collection('users').doc(uid), {
      'faceEnrolled': true,
      'faceEnrolledAt': FieldValue.serverTimestamp(),
      'faceConsent': true,
      'faceConsentAt': FieldValue.serverTimestamp(),
    });
    await b.commit();
  }

  /// Admin only: permanently deletes the biometric template.
  static Future<void> delete(String uid) async {
    final fs = FirebaseFirestore.instance;
    final b = fs.batch();
    b.delete(_ref(uid));
    b.update(fs.collection('users').doc(uid), {'faceEnrolled': false, 'faceEnrolledAt': FieldValue.delete()});
    await b.commit();
  }
}
