library matrix_gesture_detector;

import 'dart:math';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart';

typedef MatrixGestureDetectorCallback = void Function(
    Matrix4 matrix,
    Matrix4 translationDeltaMatrix,
    Matrix4 scaleDeltaMatrix,
    Matrix4 rotationDeltaMatrix);

/// [MatrixGestureDetector] detects translation, scale and rotation gestures
/// and combines them into [Matrix4] object that can be used by [Transform] widget
/// or by low level [CustomPainter] code. You can customize types of reported
/// gestures by passing [shouldTranslate], [shouldScale] and [shouldRotate]
/// parameters.
///
class MatrixGestureDetector extends StatefulWidget {
  /// [Matrix4] change notification callback
  ///
  final MatrixGestureDetectorCallback onMatrixUpdate;

  /// The [child] contained by this detector.
  ///
  /// {@macro flutter.widgets.child}
  ///
  final Widget child;

  /// Whether to detect translation gestures during the event processing.
  ///
  /// Defaults to true.
  ///
  final bool shouldTranslate;

  /// Whether to detect scale gestures during the event processing.
  ///
  /// Defaults to true.
  ///
  final bool shouldScale;

  /// Whether to detect rotation gestures during the event processing.
  ///
  /// Defaults to true.
  ///
  final bool shouldRotate;

  /// Whether [ClipRect] widget should clip [child] widget.
  ///
  /// Defaults to true.
  ///
  final bool clipChild;

  /// When set, it will be used for computing a "fixed" focal point
  /// aligned relative to the size of this widget.
  final Alignment focalPointAlignment;

  const MatrixGestureDetector({
    Key key,
    @required this.onMatrixUpdate,
    @required this.child,
    this.shouldTranslate = true,
    this.shouldScale = true,
    this.shouldRotate = true,
    this.clipChild = true,
    this.focalPointAlignment,
  })  : assert(onMatrixUpdate != null),
        assert(child != null),
        super(key: key);

  @override
  _MatrixGestureDetectorState createState() => _MatrixGestureDetectorState();

  ///
  /// Compose the matrix from translation, scale and rotation matrices - you can
  /// pass a null to skip any matrix from composition.
  ///
  /// If [matrix] is not null the result of the composing will be concatenated
  /// to that [matrix], otherwise the identity matrix will be used.
  ///
  static Matrix4 compose(Matrix4 matrix, Matrix4 translationMatrix,
      Matrix4 scaleMatrix, Matrix4 rotationMatrix) {
    if (matrix == null) matrix = Matrix4.identity();
    if (translationMatrix != null) matrix = translationMatrix * matrix;
    if (scaleMatrix != null) matrix = scaleMatrix * matrix;
    if (rotationMatrix != null) matrix = rotationMatrix * matrix;
    return matrix;
  }

  ///
  /// Decomposes [matrix] into [MatrixDecomposedValues.translation],
  /// [MatrixDecomposedValues.scale] and [MatrixDecomposedValues.rotation] components.
  ///
  static MatrixDecomposedValues decomposeToValues(Matrix4 matrix) {
    var array = matrix.applyToVector3Array([0, 0, 0, 1, 0, 0]);
    Offset translation = Offset(array[0], array[1]);
    Offset delta = Offset(array[3] - array[0], array[4] - array[1]);
    double scale = delta.distance;
    double rotation = delta.direction;
    return MatrixDecomposedValues(translation, scale, rotation);
  }
}

enum InertialGestureEvent {
  zoomIn,
  zoomOut,
  pan,
  none
}

class _MatrixGestureDetectorState extends State<MatrixGestureDetector> {
  Matrix4 translationDeltaMatrix = Matrix4.identity();
  Matrix4 scaleDeltaMatrix = Matrix4.identity();
  Matrix4 rotationDeltaMatrix = Matrix4.identity();
  Matrix4 matrix = Matrix4.identity();

  @override
  Widget build(BuildContext context) {
    Widget child =
    widget.clipChild ? ClipRect(child: widget.child) : widget.child;
    return Listener(
        onPointerDown: down,
        onPointerUp: up,
        child: GestureDetector(
          onScaleStart: onScaleStart,
          onScaleUpdate: onScaleUpdate,
          onScaleEnd: onScaleEnd,
          child: child,
        ));
  }
  InertialGestureEvent activeInertialEvent = InertialGestureEvent.none;
  int count = 0;
  DateTime secondPointerUp;
  bool twoPointerEvent = false;
  Duration twoPointerEventDuration = Duration();
  void down(PointerDownEvent e) {
    count += 1;
    twoPointerEvent = (count == 2);
  }
  void up(PointerUpEvent e) {
    count -= 1;
    if (count == 1) {
      secondPointerUp = DateTime.now();
    }
    if (twoPointerEvent) {
      if (count == 0) {
        twoPointerEventDuration = DateTime.now().difference(secondPointerUp);
      }
    }
  }

  _ValueUpdater<Offset> translationUpdater = _ValueUpdater(
    onUpdate: (oldVal, newVal) => newVal - oldVal,
  );
  _ValueUpdater<double> rotationUpdater = _ValueUpdater(
    onUpdate: (oldVal, newVal) => newVal - oldVal,
  );
  _ValueUpdater<double> scaleUpdater = _ValueUpdater(
    onUpdate: (oldVal, newVal) => newVal / oldVal,
  );


  void onScaleStart(ScaleStartDetails details) {
    translationUpdater.value = details.focalPoint;
    rotationUpdater.value = double.nan;
    scaleUpdater.value = 1.0;
    activeInertialEvent = InertialGestureEvent.none;
    endInertialGesture();
  }

  double lastScale = 1;
  Offset lastFocalPoint = Offset.zero;

  void onScaleUpdate(ScaleUpdateDetails details) {
    translationDeltaMatrix = Matrix4.identity();
    scaleDeltaMatrix = Matrix4.identity();
    rotationDeltaMatrix = Matrix4.identity();

    // handle matrix translating
    if (widget.shouldTranslate) {
      Offset translationDelta = translationUpdater.update(details.focalPoint);
      translationDeltaMatrix = _translate(translationDelta);
      matrix = translationDeltaMatrix * matrix;
    }

    Offset focalPoint;
    if (widget.focalPointAlignment != null) {
      focalPoint = widget.focalPointAlignment.alongSize(context.size);
    } else {
      RenderBox renderBox = context.findRenderObject();
      focalPoint = renderBox.globalToLocal(details.focalPoint);
    }
    lastFocalPoint = focalPoint;
    // handle matrix scaling
    if (widget.shouldScale && details.scale != 1.0) {
      double scaleDelta = scaleUpdater.update(details.scale);
      if (scaleDelta != 1) {
        lastScale = scaleDelta;
      }
//      print("scale delta: $scaleDelta");
      scaleDeltaMatrix = _scale(scaleDelta, focalPoint);
      matrix = scaleDeltaMatrix * matrix;
    }

    // handle matrix rotating
    if (widget.shouldRotate && details.rotation != 0.0) {
      if (rotationUpdater.value.isNaN) {
        rotationUpdater.value = details.rotation;
      } else {
        double rotationDelta = rotationUpdater.update(details.rotation);
        rotationDeltaMatrix = _rotate(rotationDelta, focalPoint);
        matrix = rotationDeltaMatrix * matrix;
      }
    }

    widget.onMatrixUpdate(
        matrix, translationDeltaMatrix, scaleDeltaMatrix, rotationDeltaMatrix);
  }

  Offset firstPointerVelocity = Offset.zero;
  Offset secondPointerVelocity = Offset.zero;
  Timer inertialEventTimer;
//  int lastScaleEndPointerCount = 0;
  void onScaleEnd(ScaleEndDetails details) {
    if (count == 1) {
      secondPointerVelocity = details.velocity.pixelsPerSecond;
    }
    if (count == 0) {
      firstPointerVelocity = details.velocity.pixelsPerSecond;
    }
    print("");
    print("<-- scale ending -->");
    print("pointer count: $count");
    print("twoPointerEvent: $twoPointerEvent");
    print("duration between pointers coming up: ${twoPointerEventDuration.inMilliseconds}");
    if (twoPointerEvent && (count == 0 || count == 1)) {
      if (details.velocity.pixelsPerSecond.distance != 0) {
        int duration = twoPointerEventDuration.inMilliseconds;
        print("last scale delta $lastScale");
//        print("duration between pointers coming up: $duration");
        if (widget.shouldScale && duration < 200) {
          // calculate
          beginInertialScale(lastScale, lastFocalPoint);
//          if (lastScale > 1) {
////            print("CONTINUE ZOOM IN!");
//          } else if (lastScale <= 1) {
////            print("CONTINUE ZOOM OUT!");
//          } else {
////            print("UNSURE");
//          }
        } else {
          if (widget.shouldTranslate && details.velocity.pixelsPerSecond.distance != 0) {
            beginInertialFling(firstPointerVelocity);
//            print("CONTINUE PAN");
          }
        }
      }
    } else if (count == 0) {
      if (widget.shouldTranslate && details.velocity.pixelsPerSecond.distance != 0) {
        beginInertialFling(firstPointerVelocity);
//        print("CONTINUE PAN");
      }
    }
  }

  int updateInterval = 15;
  double updateSeconds = 0.015;
  double decayFactor = 8;

  void beginInertialFling(Offset initialVelocity) {
    endInertialGesture();
    double duration = 0;
    inertialEventTimer = Timer.periodic(Duration(milliseconds: updateInterval), (Timer t) {
      duration += updateSeconds;
      double scaleFactor = exp(-decayFactor*duration);
      Offset newVelocity = initialVelocity.scale(scaleFactor, scaleFactor);
      if (newVelocity.distanceSquared < 0.1) {
        print("pan ending");
        t.cancel();
      }
      Offset newOffset = translationUpdater.value.translate(newVelocity.dx * updateSeconds, newVelocity.dy * updateSeconds);
      Offset translationDelta = translationUpdater.update(newOffset);
      translationDeltaMatrix = _translate(translationDelta);
      matrix = translationDeltaMatrix * matrix;
      widget.onMatrixUpdate(
          matrix, translationDeltaMatrix, scaleDeltaMatrix, rotationDeltaMatrix);
    });
  }

  void beginInertialScale(double endingScale, Offset focalPoint) {
    endInertialGesture();
    double currentDuration = 0;
    double totalDuration = 0.5;
    double deltaOne = endingScale - 1;
    double scale = endingScale;
    print("inital scale: $endingScale");
    print("calculated duration: $totalDuration");
    scaleUpdater.update(endingScale);
    inertialEventTimer = Timer.periodic(Duration(milliseconds: updateInterval), (Timer t) {
      currentDuration += updateSeconds;
      if (currentDuration >= totalDuration) {
        t.cancel();
        return;
      }

      double pct = currentDuration/totalDuration;
      double newScale = 1 + (scale - 1) * (1 - Curves.decelerate.transform(pct));
      newScale = scaleUpdater.update(newScale);
      print("deltaOne: $deltaOne");
      print("newScale: $newScale");
      scaleDeltaMatrix = _scale(newScale, focalPoint);
      matrix = scaleDeltaMatrix * matrix;
      widget.onMatrixUpdate(
          matrix, translationDeltaMatrix, scaleDeltaMatrix, rotationDeltaMatrix);
      scale = newScale;
//      if ((newScale - 1).abs() < 0.00001) {
//        print("ending inertial scale");
//        t.cancel();
//      }
    });
  }
  void endInertialGesture() {
    if (inertialEventTimer != null) {
      inertialEventTimer.cancel();
    }
  }

  Matrix4 _translate(Offset translation) {
    var dx = translation.dx;
    var dy = translation.dy;

    //  ..[0]  = 1       # x scale
    //  ..[5]  = 1       # y scale
    //  ..[10] = 1       # diagonal "one"
    //  ..[12] = dx      # x translation
    //  ..[13] = dy      # y translation
    //  ..[15] = 1       # diagonal "one"
    return Matrix4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1);
  }

  Matrix4 _scale(double scale, Offset focalPoint) {
    var dx = (1 - scale) * focalPoint.dx;
    var dy = (1 - scale) * focalPoint.dy;

    //  ..[0]  = scale   # x scale
    //  ..[5]  = scale   # y scale
    //  ..[10] = 1       # diagonal "one"
    //  ..[12] = dx      # x translation
    //  ..[13] = dy      # y translation
    //  ..[15] = 1       # diagonal "one"
    return Matrix4(scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1);
  }

  Matrix4 _rotate(double angle, Offset focalPoint) {
    var c = cos(angle);
    var s = sin(angle);
    var dx = (1 - c) * focalPoint.dx + s * focalPoint.dy;
    var dy = (1 - c) * focalPoint.dy - s * focalPoint.dx;

    //  ..[0]  = c       # x scale
    //  ..[1]  = s       # y skew
    //  ..[4]  = -s      # x skew
    //  ..[5]  = c       # y scale
    //  ..[10] = 1       # diagonal "one"
    //  ..[12] = dx      # x translation
    //  ..[13] = dy      # y translation
    //  ..[15] = 1       # diagonal "one"
    return Matrix4(c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, dx, dy, 0, 1);
  }
}

typedef _OnUpdate<T> = T Function(T oldValue, T newValue);

class _ValueUpdater<T> {
  final _OnUpdate<T> onUpdate;
  T value;

  _ValueUpdater({this.onUpdate});

  T update(T newValue) {
    T updated = onUpdate(value, newValue);
    value = newValue;
    return updated;
  }
}

class MatrixDecomposedValues {
  /// Translation, in most cases useful only for matrices that are nothing but
  /// a translation (no scale and no rotation).
  final Offset translation;

  /// Scaling factor.
  final double scale;

  /// Rotation in radians, (-pi..pi) range.
  final double rotation;

  MatrixDecomposedValues(this.translation, this.scale, this.rotation);

  @override
  String toString() {
    return 'MatrixDecomposedValues(translation: $translation, scale: ${scale.toStringAsFixed(3)}, rotation: ${rotation.toStringAsFixed(3)})';
  }
}