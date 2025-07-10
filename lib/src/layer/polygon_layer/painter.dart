part of 'polygon_layer.dart';

/// The [CustomPainter] used to draw [Polygon]s for the [PolygonLayer].
// TODO: We should consider exposing this publicly, as with [CirclePainter] -
// but the projected objects are private at the moment.
class _PolygonPainter<R extends Object> extends CustomPainter
    with HitDetectablePainter<R, _ProjectedPolygon<R>>, FeatureLayerUtils {
  /// Reference to the list of [_ProjectedPolygon]s
  final List<_ProjectedPolygon<R>> polygons;

  @override
  Iterable<_ProjectedPolygon<R>> get elements => polygons;

  /// Triangulated [polygons] if available
  ///
  /// Expected to be in same/corresponding order as [polygons].
  final List<List<int>?>? triangles;

  /// Reference to the bounding box of the [Polygon].
  final LatLngBounds bounds;

  /// Whether to draw per-polygon labels ([Polygon.label])
  final bool polygonLabels;

  /// Whether to draw labels last and thus over all the polygons
  final bool drawLabelsLast;

  /// See [PolygonLayer.debugAltRenderer]
  final bool debugAltRenderer;

  /// See [PolygonLayer.painterFillMethod]
  final PolygonPainterFillMethod painterFillMethod;

  /// See [PolygonLayer.invertedFill]
  final Color? invertedFill;

  /// Whether to fill polygons with a hatch (line) pattern instead of solid color
  final bool hatchFill;

  /// Color of the hatch lines (defaults to borderColor if not set)
  final Color? hatchColor;

  /// Spacing between hatch lines in logical pixels
  final double hatchSpacing;

  /// Angle of hatch lines in radians
  final double hatchAngle;

  final double? hatchStrokeWidth;

  @override
  final MapCamera camera;

  @override
  final LayerHitNotifier<R>? hitNotifier;

  /// Create a new [_PolygonPainter] instance.
  _PolygonPainter({
    required this.polygons,
    required this.triangles,
    required this.polygonLabels,
    required this.drawLabelsLast,
    required this.debugAltRenderer,
    required this.camera,
    required this.painterFillMethod,
    required this.invertedFill,
    required this.hitNotifier,
    this.hatchFill = false,
    this.hatchColor,
    this.hatchSpacing = 10.0,
    this.hatchAngle = 0.0,
    this.hatchStrokeWidth,
  }) : bounds = camera.visibleBounds {
    _helper = OffsetHelper(camera: camera);
  }

  late final OffsetHelper _helper;

  static const _minMaxLatitude = [LatLng(90, 0), LatLng(-90, 0)];
  static const _invertedHoles = true;
  static const _fillInvertedHoles = true;
  static const _flushBatchOnTranslucency = true;

  @override
  bool elementHitTest(
    _ProjectedPolygon<R> projectedPolygon, {
    required Offset point,
    required LatLng coordinate,
  }) {
    WorldWorkControl checkIfHit(double shift) {
      final (projectedCoords, _) = _helper.getOffsetsXY(
        points: projectedPolygon.points,
        shift: shift,
      );
      if (!areOffsetsVisible(projectedCoords)) {
        return WorldWorkControl.invisible;
      }

      if (projectedCoords.first != projectedCoords.last) {
        projectedCoords.add(projectedCoords.first);
      }

      final isValidPolygon = projectedCoords.length >= 3;
      final isInPolygon = isValidPolygon && isPointInPolygon(point, projectedCoords);

      final isInHole = projectedPolygon.holePoints.any(
        (points) {
          final (projectedHoleCoords, _) = _helper.getOffsetsXY(
            points: points,
            shift: shift,
          );
          if (projectedHoleCoords.first != projectedHoleCoords.last) {
            projectedHoleCoords.add(projectedHoleCoords.first);
          }

          final isValidHolePolygon = projectedHoleCoords.length >= 3;
          return isValidHolePolygon && isPointInPolygon(point, projectedHoleCoords);
        },
      );

      return (isInPolygon && !isInHole) || (!isInPolygon && isInHole) ? WorldWorkControl.hit : WorldWorkControl.visible;
    }

    return workAcrossWorlds(checkIfHit);
  }

  @override
  void paint(Canvas canvas, Size size) {
    super.paint(canvas, size);

    final trianglePoints = <Offset>[];

    Path filledPath = Path();
    Path invertedHolePaths = Path();
    final borderPath = Path();
    Color? lastColor;
    int? lastHash;
    Paint? borderPaint;

    void drawBorders() {
      if (borderPaint != null) {
        canvas.drawPath(borderPath, borderPaint);
      }
      borderPath.reset();
      lastHash = null;
    }

    void drawHatchPattern(Canvas canvas, Path path, Color color, double spacing, double angle) {
      final bounds = path.getBounds();
      final paint = Paint()
        ..color = color
        ..strokeWidth = hatchStrokeWidth ?? 1.0;
      final double sinA = math.sin(angle);
      final double cosA = math.cos(angle);
      for (double d = -bounds.height - bounds.width; d < bounds.width + bounds.height; d += spacing) {
        final Offset p1 = Offset(bounds.left + d * cosA, bounds.top + d * sinA);
        final Offset p2 = Offset(bounds.right + d * cosA, bounds.bottom + d * sinA);
        final Path linePath = Path()
          ..moveTo(p1.dx, p1.dy)
          ..lineTo(p2.dx, p2.dy);
        canvas.save();
        canvas.clipPath(path);
        canvas.drawPath(linePath, paint);
        canvas.restore();
      }
    }

    void drawPaths() {
      final Color? color = lastColor;
      if (color == null) {
        drawBorders();
        return;
      }

      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = color;

      if (trianglePoints.isNotEmpty) {
        final points = Float32List(trianglePoints.length * 2);
        for (int i = 0; i < trianglePoints.length; ++i) {
          points[i * 2] = trianglePoints[i].dx;
          points[i * 2 + 1] = trianglePoints[i].dy;
        }
        final vertices = Vertices.raw(VertexMode.triangles, points);
        canvas.drawVertices(vertices, BlendMode.src, paint);

        if (debugAltRenderer) {
          for (int i = 0; i < trianglePoints.length; i += 3) {
            canvas.drawCircle(
              trianglePoints[i],
              5,
              Paint()..color = const Color(0x7EFF0000),
            );
            canvas.drawCircle(
              trianglePoints[i + 1],
              5,
              Paint()..color = const Color(0x7E00FF00),
            );
            canvas.drawCircle(
              trianglePoints[i + 2],
              5,
              Paint()..color = const Color(0x7E0000FF),
            );

            final path = Path()
              ..addPolygon(
                [
                  trianglePoints[i],
                  trianglePoints[i + 1],
                  trianglePoints[i + 2],
                ],
                true,
              );

            canvas.drawPath(
              path,
              Paint()
                ..color = const Color(0x7EFFFFFF)
                ..style = PaintingStyle.fill,
            );

            canvas.drawPath(
              path,
              Paint()
                ..color = const Color(0xFF000000)
                ..style = PaintingStyle.stroke,
            );
          }
        }
        if (hatchFill) {
          canvas.drawPath(filledPath, paint);
          drawHatchPattern(canvas, filledPath, hatchColor ?? Colors.black, hatchSpacing, hatchAngle);
        }
      } else {
        if (hatchFill) {
          canvas.drawPath(filledPath, paint);
          drawHatchPattern(canvas, filledPath, hatchColor ?? Colors.black, hatchSpacing, hatchAngle);
        } else {
          canvas.drawPath(filledPath, paint);
        }
      }

      trianglePoints.clear();
      filledPath.reset();

      lastColor = null;

      drawBorders();
    }

    WorldWorkControl drawLabelIfVisible(
      double shift,
      _ProjectedPolygon<R> projectedPolygon,
    ) {
      final polygon = projectedPolygon.polygon;
      final painter = _buildLabelTextPainter(
        mapSize: camera.size,
        placementPoint: _helper.getOffset(
          polygon.labelPosition,
          shift: shift,
        ),
        bounds: _getBounds(camera.pixelOrigin, polygon),
        textPainter: polygon.textPainter!,
        rotationRad: camera.rotationRad,
        rotate: polygon.rotateLabel,
        padding: 20,
      );
      if (painter == null) return WorldWorkControl.invisible;

      drawPaths();

      painter(canvas);
      return WorldWorkControl.visible;
    }

    void invertFillPolygonHole(List<Offset> offsets) {
      if (!_fillInvertedHoles) return;

      if (painterFillMethod == PolygonPainterFillMethod.evenOdd) {
        invertedHolePaths.addPolygon(offsets, true);
        return;
      }
      invertedHolePaths = Path.combine(
        PathOperation.union,
        invertedHolePaths,
        Path()..addPolygon(offsets, true),
      );
    }

    void unfillPolygon(List<Offset> offsets) {
      if (painterFillMethod == PolygonPainterFillMethod.evenOdd) {
        filledPath.fillType = PathFillType.evenOdd;
        filledPath.addPolygon(offsets, true);
        return;
      }
      filledPath = Path.combine(
        PathOperation.difference,
        filledPath,
        Path()..addPolygon(offsets, true),
      );
    }

    if (invertedFill != null) {
      filledPath.reset();
      final minMaxProjected = camera.crs.projection.projectList(
        _minMaxLatitude,
        projectToSingleWorld: false,
      );
      final (minMaxY, _) = _helper.getOffsetsXY(
        points: minMaxProjected,
      );
      final maxX = viewportRect.right;
      final minX = viewportRect.left;
      final maxY = minMaxY[0].dy;
      final minY = minMaxY[1].dy;
      final rect = Rect.fromLTRB(minX, minY, maxX, maxY);
      filledPath.addRect(rect);

      for (int i = 0; i <= polygons.length - 1; i++) {
        final projectedPolygon = polygons[i];
        if (projectedPolygon.points.isEmpty) continue;

        WorldWorkControl drawPolygonAsHole(double shift) {
          final (fillOffsets, _) = _helper.getOffsetsXY(
            points: projectedPolygon.points,
            shift: shift,
          );
          if (!areOffsetsVisible(fillOffsets)) {
            return WorldWorkControl.invisible;
          }

          unfillPolygon(fillOffsets);

          if (_invertedHoles) {
            for (final singleHolePoints in projectedPolygon.holePoints) {
              final (holeOffsets, _) = _helper.getOffsetsXY(
                points: singleHolePoints,
                shift: shift,
              );
              unfillPolygon(holeOffsets);
              invertFillPolygonHole(holeOffsets);
            }
          }
          return WorldWorkControl.visible;
        }

        workAcrossWorlds(drawPolygonAsHole);
      }

      final paint = Paint()
        ..style = PaintingStyle.fill
        ..color = invertedFill!;

      canvas.drawPath(filledPath, paint);
      if (_fillInvertedHoles) {
        canvas.drawPath(invertedHolePaths, paint);
      }

      filledPath.reset();
    }

    for (int i = 0; i <= polygons.length - 1; i++) {
      final projectedPolygon = polygons[i];
      final polygon = projectedPolygon.polygon;
      if (projectedPolygon.points.isEmpty) continue;
      borderPaint = _getBorderPaint(polygon);

      final polygonTriangles = triangles?[i];

      WorldWorkControl drawIfVisible(double shift) {
        final (fillOffsets, addedWorldWidthForHoles) = _helper.getOffsetsXY(
          points: projectedPolygon.points,
          holePoints: polygonTriangles != null ? projectedPolygon.holePoints : null,
          shift: shift,
        );
        if (!areOffsetsVisible(fillOffsets)) {
          return WorldWorkControl.invisible;
        }

        if (debugAltRenderer) {
          const offsetsLabelStyle = TextStyle(
            color: Color(0xFF000000),
            fontSize: 16,
          );

          for (int i = 0; i < fillOffsets.length; i++) {
            TextPainter(
              text: TextSpan(
                text: i.toString(),
                style: offsetsLabelStyle,
              ),
              textDirection: TextDirection.ltr,
            )
              ..layout(maxWidth: 100)
              ..paint(canvas, fillOffsets[i]);
          }
        }

        final hash = polygon.renderHashCode;
        final opacity = polygon.color?.a ?? 0;
        if (lastHash != hash || (_flushBatchOnTranslucency && opacity > 0 && opacity < 1)) {
          drawPaths();
        }
        lastColor = polygon.color;
        lastHash = hash;

        if (polygon.color != null) {
          if (polygonTriangles != null) {
            final len = polygonTriangles.length;
            for (int i = 0; i < len; ++i) {
              trianglePoints.add(fillOffsets[polygonTriangles[i]]);
            }
          } else {
            filledPath.addPolygon(fillOffsets, true);
          }
        }

        void addBorderToPath(List<Offset> offsets) => _addBorderToPath(
              borderPath,
              polygon,
              offsets,
              size,
              canvas,
              borderPaint!,
            );

        if (borderPaint != null) {
          addBorderToPath(_helper
              .getOffsetsXY(
                points: projectedPolygon.points,
                shift: shift,
              )
              .$1);
        }

        for (final singleHolePoints in projectedPolygon.holePoints) {
          final (holeOffsets, _) = _helper.getOffsetsXY(
            points: singleHolePoints,
            shift: shift,
            forcedAddedWorldWidth: addedWorldWidthForHoles,
          );
          unfillPolygon(holeOffsets);
          if (!polygon.disableHolesBorder && borderPaint != null) {
            addBorderToPath(holeOffsets);
          }
        }

        return WorldWorkControl.visible;
      }

      workAcrossWorlds(drawIfVisible);

      if (!drawLabelsLast && polygonLabels && polygon.textPainter != null) {
        workAcrossWorlds(
          (double shift) => drawLabelIfVisible(shift, projectedPolygon),
        );
      }
      drawPaths();
    }

    if (polygonLabels && drawLabelsLast) {
      for (final projectedPolygon in polygons) {
        if (projectedPolygon.points.isEmpty) {
          continue;
        }
        if (projectedPolygon.polygon.textPainter == null) {
          continue;
        }
        workAcrossWorlds(
          (double shift) => drawLabelIfVisible(shift, projectedPolygon),
        );
      }
    }
  }

  Paint? _getBorderPaint(Polygon polygon) {
    if (polygon.borderStrokeWidth <= 0) {
      return null;
    }
    final isDotted = polygon.pattern.spacingFactor != null;
    return Paint()
      ..color = polygon.borderColor
      ..strokeWidth = polygon.borderStrokeWidth
      ..strokeCap = polygon.strokeCap
      ..strokeJoin = polygon.strokeJoin
      ..style = isDotted ? PaintingStyle.fill : PaintingStyle.stroke;
  }

  void _addBorderToPath(
    Path path,
    Polygon polygon,
    List<Offset> offsets,
    Size canvasSize,
    Canvas canvas,
    Paint paint,
  ) {
    final isSolid = polygon.pattern == const StrokePattern.solid();
    final isDashed = polygon.pattern.segments != null;
    final isDotted = polygon.pattern.spacingFactor != null;
    final strokeWidth = polygon.borderStrokeWidth;

    if (isSolid) {
      final SolidPixelHiker hiker = SolidPixelHiker(
        offsets: offsets,
        closePath: true,
        canvasSize: canvasSize,
        strokeWidth: strokeWidth,
      );
      hiker.addAllVisibleSegments([path]);
    } else if (isDotted) {
      final DottedPixelHiker hiker = DottedPixelHiker(
        offsets: offsets,
        stepLength: strokeWidth * polygon.pattern.spacingFactor!,
        patternFit: polygon.pattern.patternFit!,
        closePath: true,
        canvasSize: canvasSize,
        strokeWidth: strokeWidth,
      );
      for (final visibleDot in hiker.getAllVisibleDots()) {
        canvas.drawCircle(visibleDot, polygon.borderStrokeWidth / 2, paint);
      }
    } else if (isDashed) {
      final DashedPixelHiker hiker = DashedPixelHiker(
        offsets: offsets,
        segmentValues: polygon.pattern.segments!,
        patternFit: polygon.pattern.patternFit!,
        closePath: true,
        canvasSize: canvasSize,
        strokeWidth: strokeWidth,
      );

      for (final visibleSegment in hiker.getAllVisibleSegments()) {
        path.moveTo(visibleSegment.begin.dx, visibleSegment.begin.dy);
        path.lineTo(visibleSegment.end.dx, visibleSegment.end.dy);
      }
    }
  }

  ({Offset min, Offset max}) _getBounds(Offset origin, Polygon polygon) {
    final bBox = polygon.boundingBox;
    return (
      min: _helper.getOffset(bBox.southWest),
      max: _helper.getOffset(bBox.northEast),
    );
  }

  @override
  bool shouldRepaint(_PolygonPainter<R> oldDelegate) =>
      polygons != oldDelegate.polygons ||
      triangles != oldDelegate.triangles ||
      camera != oldDelegate.camera ||
      bounds != oldDelegate.bounds ||
      painterFillMethod != oldDelegate.painterFillMethod ||
      invertedFill != oldDelegate.invertedFill ||
      debugAltRenderer != oldDelegate.debugAltRenderer ||
      drawLabelsLast != oldDelegate.drawLabelsLast ||
      polygonLabels != oldDelegate.polygonLabels ||
      hitNotifier != oldDelegate.hitNotifier;
}
