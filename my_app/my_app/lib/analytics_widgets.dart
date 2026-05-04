import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:latlong2/latlong.dart';
import 'package:webview_flutter/webview_flutter.dart';

// ─── Base card ────────────────────────────────────────────────────────────────

class AnalyticCard extends StatelessWidget {
  final String title;
  final String emoji;
  final Widget child;
  final List<Color> gradientColors;

  const AnalyticCard({
    super.key,
    required this.title,
    required this.emoji,
    required this.child,
    this.gradientColors = const [Color(0xFF12122A), Color(0xFF1A1A35)],
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Row(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: GoogleFonts.sora(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          Padding(padding: const EdgeInsets.all(16), child: child),
        ],
      ),
    );
  }
}

Widget _noData(String msg) => Center(
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      msg,
      style: GoogleFonts.sora(fontSize: 13, color: Colors.white30),
    ),
  ),
);

// ─── 1 · Map of the Photos ───────────────────────────────────────────────────

class MapOfPhotosCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const MapOfPhotosCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final points = (data['points'] as List? ?? []).cast<Map>();
    if (points.isEmpty) {
      return AnalyticCard(
        title: 'Map of the Photos',
        emoji: '🗺️',
        child: _noData('No geotagged photos in this trip.'),
      );
    }

    double latSum = 0, lonSum = 0;
    for (final p in points) {
      latSum += (p['lat'] as num).toDouble();
      lonSum += (p['lon'] as num).toDouble();
    }
    final center = LatLng(latSum / points.length, lonSum / points.length);

    final markers = points.map<Marker>((p) {
      final score = (p['score'] as num?)?.toDouble() ?? 0.5;
      final color =
          Color.lerp(
            const Color(0xFF2E86C1),
            const Color(0xFF6BBF7A),
            score.clamp(0, 1),
          ) ??
          const Color(0xFF2E86C1);
      return Marker(
        point: LatLng(
          (p['lat'] as num).toDouble(),
          (p['lon'] as num).toDouble(),
        ),
        width: 14,
        height: 14,
        child: Container(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      );
    }).toList();

    return AnalyticCard(
      title: 'Map of the Photos',
      emoji: '🗺️',
      child: SizedBox(
        height: 260,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 7),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.quemory.app',
              ),
              MarkerLayer(markers: markers),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── 2 · Your Inner Circle ───────────────────────────────────────────────────

class InnerCircleCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const InnerCircleCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final faces = (data['faces'] as List? ?? []).cast<Map>();
    if (faces.isEmpty) {
      return AnalyticCard(
        title: 'Your Inner Circle',
        emoji: '👥',
        child: _noData('Not enough face data to build your inner circle.'),
      );
    }

    // Sort: rank 1 in center, 2 left, 3 right
    final sorted = List<Map>.from(faces)
      ..sort((a, b) => (a['rank'] as int).compareTo(b['rank'] as int));
    final podiumOrder = sorted.length >= 3
        ? [sorted[1], sorted[0], sorted[2]]
        : sorted.reversed.toList();

    const heights = [120.0, 160.0, 100.0];
    const medals = ['🥈', '🥇', '🥉'];
    final colors = [
      const Color(0xFF9E9E9E),
      const Color(0xFFFFD700),
      const Color(0xFFCD7F32),
    ];

    return AnalyticCard(
      title: 'Your Inner Circle',
      emoji: '👥',
      gradientColors: const [Color(0xFF1A1220), Color(0xFF22182E)],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(podiumOrder.length.clamp(0, 3), (i) {
          final face = podiumOrder[i];
          final imgPath = face['image_path'] as String? ?? '';
          final count = face['count'] as int? ?? 0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(medals[i], style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 6),
              Container(
                width: 72,
                height: heights[i],
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors[i].withValues(alpha: 0.7),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors[i].withValues(alpha: 0.3),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: imgPath.isNotEmpty
                      ? Image.file(File(imgPath), fit: BoxFit.cover)
                      : Container(
                          color: Colors.white10,
                          child: const Icon(
                            Icons.face_rounded,
                            color: Colors.white30,
                            size: 32,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$count appearances',
                style: GoogleFonts.sora(fontSize: 10, color: Colors.white54),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ─── 3 · Food Map ────────────────────────────────────────────────────────────

class FoodMapCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const FoodMapCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final total = data['total_food_photos'] as int? ?? 0;
    final topFood = data['top_food'] as String? ?? '';
    final photos = (data['top_food_photos'] as List? ?? []).cast<Map>();

    return AnalyticCard(
      title: 'Food Map',
      emoji: '🍜',
      gradientColors: const [Color(0xFF1A1208), Color(0xFF2A1E0A)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statPill('$total food photos', const Color(0xFFE67E22)),
              const SizedBox(width: 10),
              if (topFood.isNotEmpty)
                _statPill('Most eaten: $topFood', const Color(0xFF6BBF7A)),
            ],
          ),
          if (photos.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: photos.map((p) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(p['path'] as String),
                    width: 80,
                    height: 80,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Container(width: 80, height: 80, color: Colors.white10),
                  ),
                );
              }).toList(),
            ),
          ],
          if (total == 0) _noData('No food photos detected.'),
        ],
      ),
    );
  }
}

// ─── 4 · Photographer's Growth ───────────────────────────────────────────────

class PhotographersGrowthCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const PhotographersGrowthCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final entries = (data['data'] as List? ?? []).cast<Map>();
    final grade = data['overall_grade'] as String? ?? 'N/A';
    final avg = (data['avg_score'] as num?)?.toDouble() ?? 0;

    return AnalyticCard(
      title: "Photographer's Growth",
      emoji: '📈',
      gradientColors: const [Color(0xFF0A1A12), Color(0xFF0F2418)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _gradeBadge(grade),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Average score: ${(avg * 100).toStringAsFixed(1)}',
                      style: GoogleFonts.sora(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                    Text(
                      '${entries.length} photos analyzed',
                      style: GoogleFonts.sora(
                        fontSize: 11,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (entries.length >= 2) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 80,
              child: CustomPaint(
                painter: _SparklinePainter(
                  values: entries
                      .map((e) => (e['score'] as num).toDouble())
                      .toList(),
                  color: const Color(0xFF6BBF7A),
                ),
                size: const Size(double.infinity, 80),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Widget _gradeBadge(String grade) {
  const gradeColors = {
    'A+': Color(0xFF00C851),
    'A': Color(0xFF00C851),
    'B+': Color(0xFF6BBF7A),
    'B': Color(0xFF6BBF7A),
    'C+': Color(0xFFFFBB33),
    'C': Color(0xFFFFBB33),
    'D': Color(0xFFFF4444),
    'N/A': Color(0xFF555577),
  };
  final color = gradeColors[grade] ?? const Color(0xFF6BBF7A);
  return Container(
    width: 56,
    height: 56,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Center(
      child: Text(
        grade,
        style: GoogleFonts.sora(
          fontSize: 20,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    ),
  );
}

// ─── 5 · Emotional Timeline ──────────────────────────────────────────────────

class EmotionalTimelineCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const EmotionalTimelineCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final timeline = (data['timeline'] as List? ?? []).cast<Map>();
    final happiestDay = data['happiest_day'] as String? ?? '';

    return AnalyticCard(
      title: 'Emotional Timeline',
      emoji: '😊',
      gradientColors: const [Color(0xFF1A0A20), Color(0xFF280F2E)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (happiestDay.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD700).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: const Color(0xFFFFD700).withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                '🌟 Your happiest day was $happiestDay',
                style: GoogleFonts.sora(
                  fontSize: 13,
                  color: const Color(0xFFFFD700),
                ),
              ),
            ),
          if (timeline.length >= 2) ...[
            SizedBox(
              height: 80,
              child: CustomPaint(
                painter: _SparklinePainter(
                  values: timeline
                      .map((e) => (e['intensity'] as num).toDouble())
                      .toList(),
                  color: const Color(0xFFFF6B9D),
                ),
                size: const Size(double.infinity, 80),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Smile intensity over ${timeline.length} days',
              style: GoogleFonts.sora(fontSize: 11, color: Colors.white30),
            ),
          ],
          if (timeline.isEmpty) _noData('No facial expression data available.'),
        ],
      ),
    );
  }
}

// ─── 6 · World Footprint ─────────────────────────────────────────────────────

class WorldFootprintCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const WorldFootprintCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final totalKm = (data['total_km'] as num?)?.toDouble() ?? 0;
    final heatmap = (data['heatmap'] as List? ?? []).cast<Map>();
    final countries = (data['countries'] as List? ?? []).cast<String>();
    final pct = (data['pct_earth'] as num?)?.toDouble() ?? 0;

    LatLng center = const LatLng(20, 0);
    List<Marker> markers = [];
    if (heatmap.isNotEmpty) {
      double latSum = 0, lonSum = 0;
      for (final h in heatmap) {
        latSum += (h['lat'] as num).toDouble();
        lonSum += (h['lon'] as num).toDouble();
      }
      center = LatLng(latSum / heatmap.length, lonSum / heatmap.length);
      final maxCount = heatmap
          .map((h) => (h['count'] as num).toInt())
          .reduce(math.max);
      markers = heatmap.map<Marker>((h) {
        final intensity = (h['count'] as num) / maxCount;
        return Marker(
          point: LatLng(
            (h['lat'] as num).toDouble(),
            (h['lon'] as num).toDouble(),
          ),
          width: 20 + 20 * intensity,
          height: 20 + 20 * intensity,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(
                0xFF2E86C1,
              ).withValues(alpha: 0.35 + 0.4 * intensity),
              shape: BoxShape.circle,
            ),
          ),
        );
      }).toList();
    }

    return AnalyticCard(
      title: 'World Footprint',
      emoji: '🌍',
      gradientColors: const [Color(0xFF0A1220), Color(0xFF0F1A2E)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statPill(
                '${totalKm.toStringAsFixed(0)} km traveled',
                const Color(0xFF2E86C1),
              ),
              const SizedBox(width: 8),
              _statPill(
                '${pct.toStringAsExponential(1)}% of Earth',
                const Color(0xFF6BBF7A),
              ),
            ],
          ),
          if (countries.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: countries
                  .map((c) => _statPill(c, const Color(0xFF9B59B6)))
                  .toList(),
            ),
          ],
          if (heatmap.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: FlutterMap(
                  options: MapOptions(initialCenter: center, initialZoom: 4),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.quemory.app',
                    ),
                    MarkerLayer(markers: markers),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── 7 · Pet Report Card ─────────────────────────────────────────────────────

class PetReportCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const PetReportCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final best = data['best'] as Map?;
    final worst = data['worst'] as Map?;
    final total = data['total'] as int? ?? 0;

    if (best == null && worst == null) {
      return AnalyticCard(
        title: 'Pet Report Card',
        emoji: '🐾',
        child: _noData('No pet photos detected in this trip.'),
      );
    }

    return AnalyticCard(
      title: 'Pet Report Card',
      emoji: '🐾',
      gradientColors: const [Color(0xFF1A1210), Color(0xFF2A1C14)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statPill('$total pet photos found', const Color(0xFFE67E22)),
          const SizedBox(height: 14),
          Row(
            children: [
              if (best != null) _photoCard(best['path'] as String, '🏆 Best'),
              const SizedBox(width: 12),
              if (worst != null)
                _photoCard(worst['path'] as String, '📉 Blurriest'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _photoCard(String path, String label) {
    return Expanded(
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(
              File(path),
              height: 130,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  Container(height: 130, color: Colors.white10),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: GoogleFonts.sora(fontSize: 11, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

// ─── 8 · Chasing Sunsets ─────────────────────────────────────────────────────

class ChasingSunsetsCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const ChasingSunsetsCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final sunsets = (data['top_sunsets'] as List? ?? []).cast<Map>();
    final total = data['total'] as int? ?? 0;

    if (sunsets.isEmpty) {
      return AnalyticCard(
        title: 'Chasing Sunsets',
        emoji: '🌅',
        child: _noData('No sunset photos detected.'),
      );
    }

    const medals = ['🥇', '🥈', '🥉'];
    const heights = [160.0, 120.0, 100.0];
    final order = sunsets.length >= 3
        ? [sunsets[1], sunsets[0], sunsets[2]]
        : sunsets;

    return AnalyticCard(
      title: 'Chasing Sunsets',
      emoji: '🌅',
      gradientColors: const [Color(0xFF1A0E08), Color(0xFF2A1610)],
      child: Column(
        children: [
          _statPill('$total sunset shots found', const Color(0xFFFF8C00)),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(order.length.clamp(0, 3), (i) {
              final s = order[i];
              final ts = (s['timestamp'] as String? ?? '');
              String dateStr = '';
              if (ts.length >= 10) dateStr = ts.substring(0, 10);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(medals[i], style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(s['path'] as String),
                      width: 90,
                      height: heights[i.clamp(0, 2)],
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 90,
                        height: heights[i.clamp(0, 2)],
                        color: Colors.white10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (dateStr.isNotEmpty)
                    Text(
                      dateStr,
                      style: GoogleFonts.sora(
                        fontSize: 9,
                        color: Colors.white38,
                      ),
                    ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}

// ─── 9 · Time Machine ────────────────────────────────────────────────────────

class TimeMachineCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const TimeMachineCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final locations = (data['locations'] as List? ?? []).cast<Map>();
    if (locations.isEmpty) {
      return AnalyticCard(
        title: 'Time Machine',
        emoji: '⏳',
        child: _noData('Not enough repeat-location data across trips.'),
      );
    }

    return AnalyticCard(
      title: 'Time Machine',
      emoji: '⏳',
      gradientColors: const [Color(0xFF0A1218), Color(0xFF0F1C28)],
      child: Column(
        children: locations.take(3).map((loc) {
          final photos = (loc['photos'] as List? ?? []).cast<Map>();
          final count = loc['visit_count'] as int? ?? 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You visited this spot $count times',
                  style: GoogleFonts.sora(
                    fontSize: 12,
                    color: const Color(0xFF2E86C1),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                if (photos.length >= 2)
                  Row(
                    children: [
                      _timePhoto(
                        photos.first['path'] as String,
                        photos.first['date'] as String? ?? '',
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white24,
                          size: 18,
                        ),
                      ),
                      _timePhoto(
                        photos.last['path'] as String,
                        photos.last['date'] as String? ?? '',
                      ),
                    ],
                  ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _timePhoto(String path, String date) {
    return Expanded(
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(path),
              height: 100,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  Container(height: 100, color: Colors.white10),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            date,
            style: GoogleFonts.sora(fontSize: 10, color: Colors.white38),
          ),
        ],
      ),
    );
  }
}

// ─── 10 · Photo Timeline Heatmap ─────────────────────────────────────────────

class PhotoTimelineHeatmapCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const PhotoTimelineHeatmapCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final cells = (data['cells'] as List? ?? []).cast<Map>();
    if (cells.isEmpty) {
      return AnalyticCard(
        title: 'Photo Timeline Heatmap',
        emoji: '📅',
        child: _noData('No timestamp data available.'),
      );
    }

    return AnalyticCard(
      title: 'Photo Timeline Heatmap',
      emoji: '📅',
      gradientColors: const [Color(0xFF0A1A0A), Color(0xFF0F240F)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${cells.length} days with photos',
            style: GoogleFonts.sora(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: cells.map((cell) {
              final intensity = (cell['intensity'] as num).toDouble();
              final count = cell['count'] as int;
              return Tooltip(
                message: '${cell['date']}: $count photos',
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      const Color(0xFF1A2A1A),
                      const Color(0xFF39D353),
                      intensity,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                'Less',
                style: GoogleFonts.sora(fontSize: 10, color: Colors.white24),
              ),
              const SizedBox(width: 6),
              ...List.generate(
                5,
                (i) => Container(
                  margin: const EdgeInsets.only(right: 3),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      const Color(0xFF1A2A1A),
                      const Color(0xFF39D353),
                      i / 4,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'More',
                style: GoogleFonts.sora(fontSize: 10, color: Colors.white24),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── 11 · Hours of the Day Wheel ─────────────────────────────────────────────

class HoursOfDayWheelCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const HoursOfDayWheelCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final hours = (data['hours'] as List? ?? []).cast<Map>();
    final bestHour = data['best_hour_label'] as String? ?? '';

    if (hours.isEmpty) {
      return AnalyticCard(
        title: 'Hours of the Day Wheel',
        emoji: '⏰',
        child: _noData('No timestamp data.'),
      );
    }

    final counts = hours.map((h) => (h['count'] as int).toDouble()).toList();

    return AnalyticCard(
      title: 'Hours of the Day Wheel',
      emoji: '⏰',
      gradientColors: const [Color(0xFF0A0A1A), Color(0xFF12122A)],
      child: Column(
        children: [
          if (bestHour.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                '📷 Best photos are usually taken at $bestHour',
                style: GoogleFonts.sora(
                  fontSize: 13,
                  color: const Color(0xFF6BBF7A),
                ),
              ),
            ),
          SizedBox(
            height: 160,
            child: CustomPaint(
              painter: _ClockChartPainter(counts: counts),
              size: const Size(double.infinity, 160),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 12 · Trip Distance / Photo Count / Duration ─────────────────────────────

class TripStatsCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const TripStatsCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final photoCount = data['photo_count'] as int? ?? 0;
    final distanceKm = (data['distance_km'] as num?)?.toDouble() ?? 0;
    final durationDays = data['duration_days'] as int? ?? 0;
    final startDate = data['start_date'] as String? ?? '';
    final endDate = data['end_date'] as String? ?? '';

    return AnalyticCard(
      title: 'Trip Distance · Photos · Duration',
      emoji: '📊',
      gradientColors: const [Color(0xFF10101E), Color(0xFF181828)],
      child: Column(
        children: [
          if (startDate.isNotEmpty && endDate.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                '$startDate → $endDate',
                style: GoogleFonts.sora(fontSize: 12, color: Colors.white38),
              ),
            ),
          Row(
            children: [
              _bigStat(
                '${distanceKm.toStringAsFixed(0)} km',
                'Distance',
                const Color(0xFF2E86C1),
              ),
              _bigStat('$photoCount', 'Photos', const Color(0xFF6BBF7A)),
              _bigStat(
                '$durationDays days',
                'Duration',
                const Color(0xFFE67E22),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bigStat(String value, String label, Color color) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: GoogleFonts.sora(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.sora(fontSize: 10, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 13 · Camera Usage Breakdown ─────────────────────────────────────────────

class CameraUsageCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const CameraUsageCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final devices = (data['devices'] as List? ?? []).cast<Map>();
    if (devices.isEmpty) {
      return AnalyticCard(
        title: 'Camera Usage Breakdown',
        emoji: '📷',
        child: _noData('No camera EXIF data available.'),
      );
    }

    return AnalyticCard(
      title: 'Camera Usage Breakdown',
      emoji: '📷',
      gradientColors: const [Color(0xFF181018), Color(0xFF221422)],
      child: Column(
        children: devices.map((d) {
          final name = d['name'] as String? ?? 'Unknown';
          final pct = (d['pct'] as num?)?.toDouble() ?? 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: GoogleFonts.sora(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${pct.toStringAsFixed(1)}%',
                      style: GoogleFonts.sora(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF9B59B6),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF9B59B6),
                    ),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── 14 · Top Locations ──────────────────────────────────────────────────────

class TopLocationsCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const TopLocationsCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final locations = (data['locations'] as List? ?? []).cast<Map>();
    if (locations.isEmpty) {
      return AnalyticCard(
        title: 'Top Locations — Where You Return',
        emoji: '📍',
        child: _noData(
          'Visit the same location in multiple trips to unlock this.',
        ),
      );
    }

    return AnalyticCard(
      title: 'Top Locations — Where You Return',
      emoji: '📍',
      gradientColors: const [Color(0xFF0A1A1A), Color(0xFF0F2626)],
      child: Column(
        children: locations.map((loc) {
          final tripCount = loc['trip_count'] as int? ?? 0;
          final trips = (loc['trips'] as List? ?? []).cast<String>();
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E86C1).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.location_on_rounded,
                    color: Color(0xFF2E86C1),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "You've visited this spot on $tripCount trips",
                        style: GoogleFonts.sora(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                      Text(
                        trips.join(' · '),
                        style: GoogleFonts.sora(
                          fontSize: 10,
                          color: Colors.white30,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── 15 · Trip Duration Ranking ──────────────────────────────────────────────

class TripDurationRankingCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const TripDurationRankingCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final trips = (data['trips'] as List? ?? []).cast<Map>();
    if (trips.isEmpty) {
      return AnalyticCard(
        title: 'Trip Duration Ranking',
        emoji: '🏆',
        child: _noData('Need multiple trips to rank durations.'),
      );
    }

    final maxDays = trips
        .map((t) => (t['days'] as int))
        .reduce(math.max)
        .toDouble();

    return AnalyticCard(
      title: 'Trip Duration Ranking',
      emoji: '🏆',
      gradientColors: const [Color(0xFF18100A), Color(0xFF281A0F)],
      child: Column(
        children: trips.map((t) {
          final name = t['name'] as String? ?? '';
          final days = t['days'] as int? ?? 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 100,
                  child: Text(
                    name,
                    style: GoogleFonts.sora(
                      fontSize: 11,
                      color: Colors.white60,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: days / maxDays,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color.lerp(
                          const Color(0xFF2E86C1),
                          const Color(0xFFE67E22),
                          days / maxDays,
                        )!,
                      ),
                      minHeight: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$days d',
                  style: GoogleFonts.sora(fontSize: 11, color: Colors.white54),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ─── 16 · Photography DNA ────────────────────────────────────────────────────

class PhotographyDNACard extends StatelessWidget {
  final Map<String, dynamic> data;

  const PhotographyDNACard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final vibes = (data['vibes'] as List? ?? []).cast<Map>();
    if (vibes.isEmpty) {
      return AnalyticCard(
        title: 'Your Photography DNA',
        emoji: '🧬',
        child: _noData('Run /embed first to generate CLIP embeddings.'),
      );
    }

    final colors = [
      const Color(0xFF6BBF7A),
      const Color(0xFF2E86C1),
      const Color(0xFFE67E22),
      const Color(0xFF9B59B6),
      const Color(0xFFFF6B9D),
      const Color(0xFFFFD700),
      const Color(0xFF00BCD4),
      const Color(0xFFFF5722),
    ];

    return AnalyticCard(
      title: 'Your Photography DNA',
      emoji: '🧬',
      gradientColors: const [Color(0xFF08121E), Color(0xFF0C1C2E)],
      child: Column(
        children: List.generate(vibes.length, (i) {
          final vibe = vibes[i];
          final label = vibe['label'] as String? ?? '';
          final pct = (vibe['pct'] as num?)?.toDouble() ?? 0;
          final color = colors[i % colors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    label,
                    style: GoogleFonts.sora(
                      fontSize: 11,
                      color: Colors.white60,
                    ),
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Container(
                        height: 20,
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: pct / 100,
                        child: Container(
                          height: 20,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${pct.toStringAsFixed(1)}%',
                  style: GoogleFonts.sora(fontSize: 11, color: color),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// ─── 17 · Night Owl Report ───────────────────────────────────────────────────

class NightOwlReportCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const NightOwlReportCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final total = data['total_count'] as int? ?? 0;
    final midnight = data['midnight_count'] as int? ?? 0;
    final bestShots = (data['best_shots'] as List? ?? []).cast<Map>();
    final latest = data['latest_photo'] as Map?;

    if (total == 0) {
      return AnalyticCard(
        title: 'The Night Owl Report',
        emoji: '🦉',
        child: _noData('No late-night photos (10 PM–5 AM) found.'),
      );
    }

    return AnalyticCard(
      title: 'The Night Owl Report',
      emoji: '🦉',
      gradientColors: const [Color(0xFF060610), Color(0xFF0A0A1C)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statPill('$total night shots', const Color(0xFF6B5BFF)),
              const SizedBox(width: 8),
              _statPill('$midnight after midnight', Colors.indigo.shade300),
            ],
          ),
          if (latest != null &&
              (latest['time'] as String? ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '🌙 Latest photo ever: ${latest['time']}',
              style: GoogleFonts.sora(
                fontSize: 13,
                color: Colors.indigo.shade200,
              ),
            ),
          ],
          if (bestShots.isNotEmpty) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 100,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: bestShots.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final shot = bestShots[i];
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(shot['path'] as String),
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 100,
                        height: 100,
                        color: Colors.indigo.shade900,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── 18 · Key Photos ─────────────────────────────────────────────────────────

class KeyPhotosCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const KeyPhotosCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final photos = (data['photos'] as List? ?? []).cast<Map>();
    if (photos.isEmpty) {
      return AnalyticCard(
        title: 'Key Photos',
        emoji: '🖼️',
        child: _noData('No photos in this trip.'),
      );
    }

    return AnalyticCard(
      title: 'Key Photos',
      emoji: '🖼️',
      gradientColors: const [Color(0xFF10101E), Color(0xFF181828)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${photos.length} photos',
            style: GoogleFonts.sora(fontSize: 12, color: Colors.white38),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: photos.map((p) {
              final path = p['path'] as String;
              final isKey = p['is_key'] as bool? ?? false;
              return Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(
                      File(path),
                      width: 90,
                      height: 90,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 90,
                        height: 90,
                        color: Colors.white10,
                      ),
                    ),
                  ),
                  if (isKey)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFD700),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(
                          Icons.star_rounded,
                          color: Colors.black,
                          size: 10,
                        ),
                      ),
                    ),
                ],
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ─── 19 · Ben Aharon Marenkov Special ────────────────────────────────────────

class BenAharonSpecialCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final int tripId;

  const BenAharonSpecialCard({
    super.key,
    required this.data,
    required this.tripId,
  });

  @override
  State<BenAharonSpecialCard> createState() => _BenAharonSpecialCardState();
}

class _BenAharonSpecialCardState extends State<BenAharonSpecialCard> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => setState(() => _loading = false),
        ),
      )
      ..loadRequest(
        Uri.parse('http://localhost:8000/trips/${widget.tripId}/ben-aharon'),
      );
  }

  @override
  Widget build(BuildContext context) {
    return AnalyticCard(
      title: 'The Ben Aharon Marenkov Special',
      emoji: '✨',
      gradientColors: const [Color(0xFF0f0c29), Color(0xFF302b63)],
      child: SizedBox(
        height: 300,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_loading)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
// ─── Shared helpers ───────────────────────────────────────────────────────────

Widget _statPill(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text(
      text,
      style: GoogleFonts.sora(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );
}

// ─── Custom Painters ─────────────────────────────────────────────────────────

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  _SparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minV = values.reduce(math.min);
    final maxV = values.reduce(math.max);
    final range = (maxV - minV).abs();
    final normalised = range > 0
        ? values.map((v) => (v - minV) / range).toList()
        : values;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.3), Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    final path = ui.Path();
    final fillPath = ui.Path();
    final dx = size.width / (normalised.length - 1);

    for (int i = 0; i < normalised.length; i++) {
      final x = i * dx;
      final y = size.height * (1 - normalised[i]);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo((normalised.length - 1) * dx, size.height);
    fillPath.close();

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, paint);

    // Dot at peak
    final peak = normalised.indexOf(normalised.reduce(math.max));
    final px = peak * dx;
    final py = size.height * (1 - normalised[peak]);
    canvas.drawCircle(Offset(px, py), 4, Paint()..color = color);
    canvas.drawCircle(
      Offset(px, py),
      4,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color;
}

class _ClockChartPainter extends CustomPainter {
  final List<double> counts;

  _ClockChartPainter({required this.counts});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;
    final maxCount = counts.reduce(math.max).clamp(1, double.infinity);

    final bgPaint = Paint()
      ..color = Colors.white10
      ..style = PaintingStyle.stroke
      ..strokeWidth = 20;
    canvas.drawCircle(center, radius, bgPaint);

    final sliceAngle = 2 * math.pi / 24;

    for (int h = 0; h < 24; h++) {
      final value = counts[h] / maxCount;
      if (value <= 0) continue;

      final startAngle = -math.pi / 2 + h * sliceAngle;
      final sweep = sliceAngle * 0.85;

      // Color by time of day
      Color c;
      if (h >= 6 && h < 12) {
        c = const Color(0xFFF9CA24); // morning gold
      } else if (h >= 12 && h < 18)
        c = const Color(0xFF2E86C1); // afternoon blue
      else if (h >= 18 && h < 22)
        c = const Color(0xFFE67E22); // evening orange
      else
        c = const Color(0xFF6B5BFF); // night purple

      final paint = Paint()
        ..color = c.withValues(alpha: 0.3 + 0.7 * value)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18 * value + 4
        ..strokeCap = StrokeCap.butt;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweep,
        false,
        paint,
      );
    }

    // Center label
    final textPainter = TextPainter(
      text: TextSpan(
        text: '24h',
        style: TextStyle(
          color: Colors.white38,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          fontFamily: GoogleFonts.sora().fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(_ClockChartPainter old) => old.counts != counts;
}
