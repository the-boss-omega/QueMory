import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

class WrappedPage extends StatefulWidget {
  const WrappedPage({super.key});

  @override
  State<WrappedPage> createState() => _WrappedPageState();
}

class _WrappedPageState extends State<WrappedPage>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _stats;
  bool _loading = true;
  String? _error;

  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();
    _loadStats();
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStats() async {
    try {
      final resp = await http.get(
        Uri.parse('http://localhost:8000/wrapped/stats'),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        setState(() {
          _stats = jsonDecode(resp.body) as Map<String, dynamic>;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Server error ${resp.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach server';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Wrapped',
          style: GoogleFonts.sora(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white60),
            onPressed: () {
              setState(() {
                _loading = true;
                _error = null;
                _stats = null;
              });
              _animCtrl.reset();
              _animCtrl.forward();
              _loadStats();
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF6BBF7A)),
            )
          : _error != null
          ? Center(
              child: Text(
                _error!,
                style: GoogleFonts.sora(color: Colors.white38),
              ),
            )
          : _buildContent(),
    );
  }

  Widget _buildContent() {
    final stats = _stats!;
    final totalPhotos = stats['total_photos'] as int? ?? 0;
    final totalTrips = stats['total_trips'] as int? ?? 0;
    final totalKm = (stats['total_distance_km'] as num?)?.toDouble() ?? 0;
    final totalDays = stats['total_days_traveled'] as int? ?? 0;
    final bestPath = stats['best_photo_path'] as String?;

    final statCards = [
      _StatCard(
        icon: Icons.photo_library_rounded,
        value: totalPhotos.toString(),
        label: 'Photos Captured',
        color: const Color(0xFF6BBF7A),
        delay: 0.0,
        animCtrl: _animCtrl,
      ),
      _StatCard(
        icon: Icons.flight_takeoff_rounded,
        value: totalTrips.toString(),
        label: 'Trips Taken',
        color: const Color(0xFF2E86C1),
        delay: 0.1,
        animCtrl: _animCtrl,
      ),
      _StatCard(
        icon: Icons.route_rounded,
        value: '${_formatKm(totalKm)} km',
        label: 'Distance Traveled',
        color: const Color(0xFFE67E22),
        delay: 0.2,
        animCtrl: _animCtrl,
      ),
      _StatCard(
        icon: Icons.calendar_today_rounded,
        value: '$totalDays',
        label: 'Days on the Road',
        color: const Color(0xFF9B59B6),
        delay: 0.3,
        animCtrl: _animCtrl,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Hero headline
          _buildHeadline(totalPhotos, totalTrips),
          const SizedBox(height: 32),

          // Stat cards grid
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1.4,
            children: statCards,
          ),
          const SizedBox(height: 24),

          // Best photo card
          if (bestPath != null) _buildBestPhotoCard(bestPath),
        ],
      ),
    );
  }

  Widget _buildHeadline(int photos, int trips) {
    return AnimatedBuilder(
      animation: _animCtrl,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(
          _animCtrl.value.clamp(0.0, 1.0),
        );
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 30 * (1 - t)),
            child: child,
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your Year in',
            style: GoogleFonts.sora(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: Colors.white38,
            ),
          ),
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [Color(0xFF6BBF7A), Color(0xFF2E86C1)],
            ).createShader(bounds),
            child: Text(
              'Photos',
              style: GoogleFonts.sora(
                fontSize: 52,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$photos memories across $trips adventures.',
            style: GoogleFonts.sora(
              fontSize: 15,
              color: Colors.white54,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBestPhotoCard(String path) {
    return AnimatedBuilder(
      animation: _animCtrl,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(
          (_animCtrl.value - 0.4).clamp(0.0, 0.6) / 0.6,
        );
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 20 * (1 - t)),
            child: child,
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'YOUR BEST SHOT',
            style: GoogleFonts.sora(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white38,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF6BBF7A).withValues(alpha: 0.25),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.file(
                File(path),
                width: double.infinity,
                height: 240,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  height: 240,
                  color: Colors.white10,
                  child: const Icon(
                    Icons.broken_image_rounded,
                    color: Colors.white24,
                    size: 48,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatKm(double km) {
    if (km >= 1000) return '${(km / 1000).toStringAsFixed(1)}k';
    return km.toStringAsFixed(0);
  }
}

// ─── Animated stat card ───────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  final double delay;
  final AnimationController animCtrl;

  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
    required this.delay,
    required this.animCtrl,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animCtrl,
      builder: (context, child) {
        final progress = ((animCtrl.value - delay) / (1.0 - delay)).clamp(
          0.0,
          1.0,
        );
        final t = Curves.easeOutBack.transform(progress);
        return Opacity(
          opacity: progress.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.7 + 0.3 * t, child: child),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF12122A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.12),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: GoogleFonts.sora(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                Text(
                  label,
                  style: GoogleFonts.sora(
                    fontSize: 11,
                    color: Colors.white38,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
