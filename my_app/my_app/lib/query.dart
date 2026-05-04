import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

class QueryPage extends StatefulWidget {
  const QueryPage({super.key});

  @override
  State<QueryPage> createState() => _QueryPageState();
}

class _QueryPageState extends State<QueryPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _isSearching = true;
    });
    debugPrint('searched');

    try {
      final uri = Uri.parse(
        'http://localhost:8000/search',
      ).replace(queryParameters: {'q': query, 'top_k': '5'});
      final response = await http.get(uri);
      if (!mounted) return;

      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        setState(() {
          _searchResults = list.cast<Map<String, dynamic>>();
        });
        for (final r in _searchResults) {
          debugPrint('  ${r['score']} ${r['name']}');
        }
      } else {
        debugPrint('Search failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Search error: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: Column(
              children: [
                const SizedBox(height: 40),
                Text(
                  'Query',
                  style: GoogleFonts.sora(
                    fontSize: 128,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF1A5276),
                    height: 1.15,
                    letterSpacing: -1.0,
                  ),
                ),
                Text(
                  'what do you want to find?',
                  style: GoogleFonts.sora(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: const Color(0xFF2E86C1),
                  ),
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: 400,
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search your trips...',
                      hintStyle: GoogleFonts.sora(
                        color: Colors.grey.shade400,
                        fontSize: 14,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF5F5F5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    style: GoogleFonts.sora(fontSize: 14),
                    onSubmitted: (_) => _performSearch(),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 200,
                  height: 42,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1A5276), Color(0xFF2D8B4E)],
                      ),
                    ),
                    child: ElevatedButton(
                      onPressed: _isSearching ? null : _performSearch,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        disabledBackgroundColor: Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isSearching
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              'Search',
                              style: GoogleFonts.sora(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: 340,
                  height: 360,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      return CustomPaint(
                        painter: GlobePainter(
                          rotation: _controller.value * 2 * pi,
                        ),
                      );
                    },
                  ),
                ),
                if (_searchResults.isNotEmpty) ...[
                  const SizedBox(height: 32),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: _searchResults.map((result) {
                        final path = result['path'] as String;
                        final name = result['name'] as String;
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            File(path),
                            width: 180,
                            height: 180,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, err, stack) => Container(
                              width: 180,
                              height: 180,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Center(
                                child: Text(
                                  name,
                                  style: GoogleFonts.sora(
                                    fontSize: 10,
                                    color: Colors.grey.shade500,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 60),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Point3D {
  final double x, y, z, origTheta, origPhi;
  const _Point3D(this.x, this.y, this.z, this.origTheta, this.origPhi);
}

class GlobePainter extends CustomPainter {
  final double rotation;

  static final List<_Point3D> _points = _generatePoints();
  static final List<bool> _landMask = _generateLandMask();

  GlobePainter({required this.rotation});

  static List<_Point3D> _generatePoints() {
    final points = <_Point3D>[];
    final random = Random(1337);

    for (int i = 0; i < 750; i++) {
      final u = random.nextDouble();
      final v = random.nextDouble();
      final phi = acos(1 - 2 * u);
      final theta = 2 * pi * v;

      final x = sin(phi) * cos(theta);
      final y = cos(phi);
      final z = sin(phi) * sin(theta);

      points.add(_Point3D(x, y, z, theta, phi));
    }

    return points;
  }

  static List<bool> _generateLandMask() {
    return _points.map((p) {
      double v =
          sin(2.5 * p.origPhi + 0.3) * cos(3.0 * p.origTheta + 0.7) +
          0.5 * sin(4.0 * p.origPhi - 1.2) * cos(2.0 * p.origTheta + 1.5) +
          0.3 * cos(5.0 * p.origPhi + 0.5) * sin(4.5 * p.origTheta - 0.3);
      return v > 0.15;
    }).toList();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final radius = size.width / 2 * 0.88;

    final cosY = cos(rotation);
    final sinY = sin(rotation);

    const tiltAngle = 0.22;
    final cosX = cos(tiltAngle);
    final sinX = sin(tiltAngle);

    final orbitPaint = Paint()
      ..color = const Color(0xFF2E86C1).withOpacity(0.18)
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke;
    final orbitRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: radius * 2.0,
      height: radius * 2.0 * sinX,
    );
    canvas.drawOval(orbitRect, orbitPaint);

    final rendered = <({double sx, double sy, double depth, int index})>[];

    for (int i = 0; i < _points.length; i++) {
      final p = _points[i];
      final rx = p.x * cosY - p.z * sinY;
      final ry = p.y;
      final rz = p.x * sinY + p.z * cosY;

      final tx = rx;
      final ty = ry * cosX - rz * sinX;
      final tz = ry * sinX + rz * cosX;

      final depth = (tz + 1) / 2;

      rendered.add((
        sx: cx + tx * radius,
        sy: cy - ty * radius,
        depth: depth,
        index: i,
      ));
    }

    rendered.sort((a, b) => a.depth.compareTo(b.depth));

    for (final r in rendered) {
      final dotSize = 1.0 + r.depth * 2.8;
      final opacity = 0.18 + r.depth * 0.82;

      final p = _points[r.index];
      final isLand = _landMask[r.index];
      final color = _globeColor(p.origTheta / (2 * pi), isLand, p.origPhi);

      canvas.drawCircle(
        Offset(r.sx, r.sy),
        dotSize,
        Paint()
          ..color = color.withOpacity(opacity)
          ..style = PaintingStyle.fill,
      );
    }
  }

  Color _globeColor(double t, bool isLand, double phi) {
    if (phi < 0.35 || phi > pi - 0.35) {
      return const Color(0xFFD6E8F0);
    }
    if (isLand) {
      final variation = sin(t * 12) * 0.15;
      return Color.lerp(
        const Color(0xFF2D8B4E),
        const Color(0xFF6BBF7A),
        (t + variation).clamp(0.0, 1.0),
      )!;
    }
    return Color.lerp(const Color(0xFF1A5276), const Color(0xFF2E86C1), t)!;
  }

  @override
  bool shouldRepaint(GlobePainter oldDelegate) =>
      oldDelegate.rotation != rotation;
}
