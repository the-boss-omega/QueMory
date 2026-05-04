import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'analytics_widgets.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

class TripsPage extends StatefulWidget {
  const TripsPage({super.key});

  @override
  State<TripsPage> createState() => _TripsPageState();
}

class _TripsPageState extends State<TripsPage> {
  final List<Map<String, dynamic>> _trips = [];
  bool _isDetecting = false;

  @override
  void initState() {
    super.initState();
    _loadTrips();
  }

  Future<void> _loadTrips() async {
    try {
      final response = await http.get(Uri.parse('http://localhost:8000/trips'));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          _trips.clear();
          for (final t in data) {
            _trips.add({
              'id': t['id'],
              'name': t['name'],
              'description': t['description'],
              'start_date': t['start_date'],
              'end_date': t['end_date'],
              'cover_photo_path': t['cover_photo_path'],
              'total_photos': t['total_photos'],
            });
          }
        });
      }
    } catch (e) {
      debugPrint('Load trips error: $e');
    }
  }

  Future<void> _detectTrips() async {
    setState(() => _isDetecting = true);
    try {
      final response = await http.post(
        Uri.parse('http://localhost:8000/detect-trips'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newTrips = data['new_trips'] as int? ?? 0;
        final merged = data['merged'] as int? ?? 0;

        await _loadTrips();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                newTrips > 0
                    ? '$newTrips new trip${newTrips > 1 ? 's' : ''} found!'
                    : merged > 0
                    ? 'Added photos to existing trips'
                    : 'No new trips detected',
                style: GoogleFonts.sora(fontWeight: FontWeight.w500),
              ),
              backgroundColor: newTrips > 0
                  ? const Color(0xFF2D8B4E)
                  : const Color(0xFF2E86C1),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Detect trips error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to detect trips. Is the server running?',
              style: GoogleFonts.sora(fontWeight: FontWeight.w500),
            ),
            backgroundColor: Colors.red.shade600,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() => _isDetecting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'My Trips',
          style: GoogleFonts.sora(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: const Color(0xFF1A5276),
          ),
        ),
      ),
      body: _EmptyState(trips: _trips, onTripsChanged: () => setState(() {})),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A5276), Color(0xFF2E86C1)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1A5276).withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: _isDetecting ? null : _detectTrips,
                child: _isDetecting
                    ? const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.travel_explore_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF2D8B4E), Color(0xFF6BBF7A)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF2D8B4E).withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () {
                  _showAddTripDialog(context);
                },
                child: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddTripDialog(BuildContext context) {
    final nameController = TextEditingController();
    final notesController = TextEditingController();

    showGeneralDialog(
      context: context,
      barrierLabel: 'Add Trip',
      barrierDismissible: false,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (context, animation, secondaryAnimation) {
        bool isCreating = false;
        String? errorText;
        String? selectedFolder;
        return Center(
          child: Material(
            color: Colors.transparent,
            child: StatefulBuilder(
              builder: (context, setDialogState) {
                return PopScope(
                  canPop: !isCreating,
                  child: Container(
                    width: 400,
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 30,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'New Trip',
                          style: GoogleFonts.sora(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF1A5276),
                          ),
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: nameController,
                          decoration: InputDecoration(
                            hintText: 'Trip name (e.g. Korea 2026)',
                            hintStyle: GoogleFonts.sora(
                              color: Colors.grey.shade400,
                            ),
                            filled: true,
                            fillColor: const Color(0xFFF5F5F5),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                          ),
                          style: GoogleFonts.sora(fontSize: 16),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final path = await FilePicker.platform
                                  .getDirectoryPath(
                                    dialogTitle: 'Select image folder',
                                  );
                              if (path != null) {
                                setDialogState(() => selectedFolder = path);
                              }
                            },
                            icon: const Icon(Icons.photo_library_outlined),
                            label: Text(
                              selectedFolder != null
                                  ? selectedFolder!.split(RegExp(r'[\\/]')).last
                                  : 'Select Images',
                              style: GoogleFonts.sora(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              side: BorderSide(
                                color: selectedFolder != null
                                    ? const Color(0xFF2D8B4E)
                                    : const Color(0xFF2E86C1),
                              ),
                              foregroundColor: selectedFolder != null
                                  ? const Color(0xFF2D8B4E)
                                  : const Color(0xFF2E86C1),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Extra Information',
                            style: GoogleFonts.sora(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          maxLines: 5,
                          controller: notesController,
                          decoration: InputDecoration(
                            hintText:
                                'Add any extra information about this trip...',
                            hintStyle: GoogleFonts.sora(
                              color: Colors.grey.shade400,
                            ),
                            filled: true,
                            fillColor: const Color(0xFFF5F5F5),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 16,
                            ),
                          ),
                          style: GoogleFonts.sora(fontSize: 15),
                        ),
                        if (errorText != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              errorText!,
                              style: GoogleFonts.sora(
                                fontSize: 13,
                                color: Colors.red.shade600,
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: isCreating
                                    ? null
                                    : () => Navigator.pop(context),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                                child: Text(
                                  'Cancel',
                                  style: GoogleFonts.sora(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: isCreating
                                        ? Colors.grey.shade300
                                        : Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(14),
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF1A5276),
                                      Color(0xFF2D8B4E),
                                    ],
                                  ),
                                ),
                                child: TextButton(
                                  onPressed: isCreating
                                      ? null
                                      : () async {
                                          final name = nameController.text
                                              .trim();
                                          final notes = notesController.text
                                              .trim();
                                          if (name.isEmpty) return;
                                          setDialogState(
                                            () => isCreating = true,
                                          );
                                          try {
                                            final response = await http.post(
                                              Uri.parse(
                                                'http://localhost:8000/trips',
                                              ),
                                              headers: {
                                                'Content-Type':
                                                    'application/json',
                                              },
                                              body: jsonEncode({
                                                'name': name,
                                                'notes': notes,
                                                'folder': ?selectedFolder,
                                              }),
                                            );
                                            if (response.statusCode == 200) {
                                              final data = jsonDecode(
                                                response.body,
                                              );
                                              setState(() {
                                                _trips.add({
                                                  'id': data['trip_id'],
                                                  'name': data['name'],
                                                  'description':
                                                      data['description'],
                                                });
                                              });
                                            } else {
                                              setDialogState(() {
                                                isCreating = false;
                                                errorText =
                                                    'Server error (${response.statusCode}). Try again.';
                                              });
                                              return;
                                            }
                                          } catch (e) {
                                            debugPrint('Create trip error: $e');
                                            setDialogState(() {
                                              isCreating = false;
                                              errorText =
                                                  'Failed to create trip. Is the server running?';
                                            });
                                            return;
                                          }
                                          if (context.mounted) {
                                            Navigator.pop(context);
                                          }
                                        },
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                  ),
                                  child: isCreating
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Text(
                                          'Create',
                                          style: GoogleFonts.sora(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }
}

class _BigSquareButton extends StatefulWidget {
  final Map<String, dynamic> tripData;

  const _BigSquareButton({required this.tripData});

  @override
  State<_BigSquareButton> createState() => _BigSquareButtonState();
}

class _BigSquareButtonState extends State<_BigSquareButton> {
  void _showTripPanel(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, _, _) => _TripDetailPage(tripData: widget.tripData),
        transitionsBuilder: (_, anim, _, child) {
          return SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(0, 0.05),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
                ),
            child: FadeTransition(opacity: anim, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.tripData['name'] as String;
    final imagePath = widget.tripData['cover_photo_path'] as String?;
    return SizedBox(
      width: 180,
      height: 120,
      child: ElevatedButton(
        onPressed: () => _showTripPanel(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 3,
          padding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
        child: Column(
          children: [
            Expanded(
              child: imagePath != null
                  ? Image.file(
                      File(imagePath),
                      width: double.infinity,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF1A5276), Color(0xFF2E86C1)],
                        ),
                      ),
                      child: const Icon(
                        Icons.explore_rounded,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
            ),
            SizedBox(
              height: 40,
              child: Center(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.sora(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════
// Trip Detail Page — full analytics view
// ═══════════════════════════════════════════════

class _TripDetailPage extends StatefulWidget {
  final Map<String, dynamic> tripData;

  const _TripDetailPage({required this.tripData});

  @override
  State<_TripDetailPage> createState() => _TripDetailPageState();
}

class _TripDetailPageState extends State<_TripDetailPage> {
  Map<String, dynamic>? _analytics;
  bool _openingStory = false;
  bool _analyticsStale = true;
  String? _storyError;
  bool _addingPhotos = false;

  // Trip content
  List<Map<String, dynamic>> _photos = [];
  List<Map<String, dynamic>> _locations = [];
  bool _contentLoading = true;

  // Collaborators (stored in trip notes or as a separate field; editable)
  final List<String> _collaborators = [];

  @override
  void initState() {
    super.initState();
    _loadTripContent();
  }

  Future<void> _loadTripContent() async {
    final tripId = widget.tripData['id'];
    try {
      final results = await Future.wait([
        http.get(Uri.parse('http://localhost:8000/trips/$tripId/photos')),
        http.get(Uri.parse('http://localhost:8000/trips/$tripId/locations')),
      ]);
      if (!mounted) return;
      final photosResp = results[0];
      final locsResp = results[1];
      setState(() {
        if (photosResp.statusCode == 200) {
          _photos = (jsonDecode(photosResp.body) as List)
              .cast<Map<String, dynamic>>();
        }
        if (locsResp.statusCode == 200) {
          _locations = (jsonDecode(locsResp.body) as List)
              .cast<Map<String, dynamic>>();
        }
        _contentLoading = false;
      });
    } catch (e) {
      debugPrint('Load trip content error: $e');
      if (mounted) setState(() => _contentLoading = false);
    }
  }

  Future<bool> _ensureAnalytics({bool force = false}) async {
    if (_analytics != null && !_analyticsStale && !force) {
      return true;
    }

    setState(() {
      _openingStory = true;
      _storyError = null;
    });

    try {
      final tripId = widget.tripData['id'];
      final uri = Uri.parse('http://localhost:8000/trips/$tripId/analytics')
          .replace(
            queryParameters: (force || _analyticsStale)
                ? {'force': 'true'}
                : null,
          );
      final resp = await http.get(uri);
      if (!mounted) return false;
      if (resp.statusCode == 200) {
        final analytics = jsonDecode(resp.body) as Map<String, dynamic>;
        setState(() {
          _analytics = analytics;
          _analyticsStale = false;
          _openingStory = false;
        });
        return true;
      } else {
        setState(() {
          _storyError = 'Server error ${resp.statusCode}';
          _openingStory = false;
        });
        return false;
      }
    } catch (e) {
      if (!mounted) return false;
      setState(() {
        _storyError = 'Could not reach server';
        _openingStory = false;
      });
      return false;
    }
  }

  Future<void> _addPhotos() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select images folder to add',
    );
    if (path == null) return;
    setState(() => _addingPhotos = true);
    try {
      final tripId = widget.tripData['id'];
      final resp = await http.post(
        Uri.parse('http://localhost:8000/trips/$tripId/add-photos'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'folder': path}),
      );
      if (resp.statusCode == 200 && mounted) {
        setState(() {
          _analytics = null;
          _analyticsStale = true;
          _storyError = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Photos added! Analytics will refresh when you open the story.',
              style: GoogleFonts.sora(),
            ),
            backgroundColor: const Color(0xFF2D8B4E),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Add photos error: $e');
    } finally {
      if (mounted) setState(() => _addingPhotos = false);
    }
  }

  Future<void> _shareTrip() async {
    final ready = await _ensureAnalytics();
    if (!ready || !mounted || _analytics == null) return;

    final kpData = _analytics!['key_photos'] as Map?;
    final allPhotos = (kpData?['photos'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    // Sort by aesthetic score descending, cap at 10 (Instagram carousel limit)
    final sorted = [...allPhotos]
      ..sort(
        (a, b) => ((b['aesthetic_score'] as num?) ?? 0).compareTo(
          (a['aesthetic_score'] as num?) ?? 0,
        ),
      );
    final toShare = sorted.take(10).toList();

    if (toShare.isEmpty || !mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Preparing photos for sharing...')),
    );

    try {
      final tmpDir = await getTemporaryDirectory();
      final files = <XFile>[];

      for (final photo in toShare) {
        final path = photo['file_path'] as String? ?? photo['path'] as String?;
        if (path == null) continue;
        final uri = Uri.parse(
          'http://localhost:8000/image',
        ).replace(queryParameters: {'path': path});
        final resp = await http.get(uri);
        if (resp.statusCode != 200) continue;
        final ext = path.toLowerCase().endsWith('.png') ? 'png' : 'jpg';
        final tmpFile = File(
          '${tmpDir.path}/quemory_share_${files.length}.$ext',
        );
        await tmpFile.writeAsBytes(resp.bodyBytes);
        files.add(XFile(tmpFile.path));
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No photos available to share.')),
        );
        return;
      }

      await Share.shareXFiles(
        files,
        subject: widget.tripData['name'] as String? ?? 'My Trip',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Share failed: $e')));
    }
  }

  Future<void> _openWrappedStory() async {
    final ready = await _ensureAnalytics();
    if (!ready || !mounted || _analytics == null) return;

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, _, _) => _TripWrappedStory(
          tripName: widget.tripData['name'] as String,
          analytics: _analytics!,
        ),
        transitionsBuilder: (_, anim, _, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tripData = widget.tripData;
    final name = tripData['name'] as String;
    final notes = tripData['description'] as String? ?? '';
    final coverPath = tripData['cover_photo_path'] as String?;
    final startDate = tripData['start_date'] as String? ?? '';
    final endDate = tripData['end_date'] as String? ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A14),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            stretch: true,
            backgroundColor: const Color(0xFF0A0A14),
            foregroundColor: Colors.white,
            leading: IconButton(
              icon: Container(
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(6),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                icon: Container(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: _addingPhotos
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(
                          Icons.add_photo_alternate_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                ),
                onPressed: _addingPhotos ? null : _addPhotos,
              ),
              IconButton(
                icon: Container(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: const Icon(
                    Icons.ios_share_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                onPressed: _shareTrip,
              ),
              const SizedBox(width: 8),
            ],
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(60, 0, 16, 16),
              title: Text(
                name,
                style: GoogleFonts.sora(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
                ),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (coverPath != null)
                    Image.file(
                      File(coverPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _gradientHero(),
                    )
                  else
                    _gradientHero(),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.45, 1.0],
                        colors: [Colors.transparent, Color(0xFF0A0A14)],
                      ),
                    ),
                  ),
                  if (startDate.isNotEmpty)
                    Positioned(
                      bottom: 50,
                      left: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$startDate${endDate.isNotEmpty ? ' → $endDate' : ''}',
                          style: GoogleFonts.sora(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── KEY DATA ──────────────────────────────────────────
                  const SizedBox(height: 8),
                  _sectionLabel('KEY DATA'),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 12,
                      children: [
                        if (startDate.isNotEmpty)
                          _dataChip(
                            Icons.calendar_today_rounded,
                            'Start',
                            startDate,
                          ),
                        if (endDate.isNotEmpty)
                          _dataChip(Icons.event_rounded, 'End', endDate),
                        _dataChip(
                          Icons.photo_library_rounded,
                          'Photos',
                          _contentLoading ? '…' : '${_photos.length}',
                        ),
                        _dataChip(
                          Icons.location_on_rounded,
                          'Stops',
                          _contentLoading ? '…' : '${_locations.length}',
                        ),
                        if (tripData['total_photos'] != null &&
                            (tripData['total_photos'] as int) > 0)
                          _dataChip(
                            Icons.photo_camera_rounded,
                            'Total',
                            '${tripData['total_photos']} raw',
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── ABOUT ─────────────────────────────────────────────────
                  _sectionLabel('ABOUT THIS TRIP'),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () {
                      showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          backgroundColor: const Color(0xFF12122A),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          title: Text(
                            'About This Trip',
                            style: GoogleFonts.sora(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          content: Text(
                            notes.isNotEmpty
                                ? notes
                                : 'No description added yet.',
                            style: GoogleFonts.sora(
                              fontSize: 14,
                              color: notes.isNotEmpty
                                  ? Colors.white70
                                  : Colors.white30,
                              height: 1.6,
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(
                                'Close',
                                style: GoogleFonts.sora(
                                  color: const Color(0xFF6BBF7A),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: notes.isNotEmpty
                          ? Text(
                              notes,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.sora(
                                fontSize: 14,
                                color: Colors.white70,
                                height: 1.6,
                              ),
                            )
                          : Text(
                              'No description yet. Tap to view.',
                              style: GoogleFonts.sora(
                                fontSize: 13,
                                color: Colors.white30,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── PHOTOS ───────────────────────────────────────────────
                  _sectionLabel('PHOTOS'),
                  const SizedBox(height: 10),
                  if (_contentLoading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: CircularProgressIndicator(
                          color: Color(0xFF6BBF7A),
                          strokeWidth: 2,
                        ),
                      ),
                    )
                  else if (_photos.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Text(
                        'No photos yet. Tap + to add photos.',
                        style: GoogleFonts.sora(
                          fontSize: 13,
                          color: Colors.white30,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    SizedBox(
                      height: 110,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _photos.length > 20 ? 20 : _photos.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (ctx, i) {
                          final p = _photos[i];
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              File(p['path'] as String),
                              width: 110,
                              height: 110,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => Container(
                                width: 110,
                                height: 110,
                                color: Colors.white10,
                                child: const Icon(
                                  Icons.broken_image_rounded,
                                  color: Colors.white30,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 24),

                  // ── COLLABORATORS ─────────────────────────────────────────
                  Row(
                    children: [
                      _sectionLabel('COLLABORATORS'),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _promptAddCollaborator(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '+ Add',
                            style: GoogleFonts.sora(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _collaborators.isEmpty
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Text(
                            'No collaborators yet. Tap + Add to add people who joined this trip.',
                            style: GoogleFonts.sora(
                              fontSize: 13,
                              color: Colors.white30,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _collaborators.map((name) {
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF1A5276,
                                ).withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: const Color(
                                    0xFF2E86C1,
                                  ).withValues(alpha: 0.4),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.person_rounded,
                                    color: Colors.white54,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    name,
                                    style: GoogleFonts.sora(
                                      fontSize: 13,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  GestureDetector(
                                    onTap: () => setState(
                                      () => _collaborators.remove(name),
                                    ),
                                    child: const Icon(
                                      Icons.close_rounded,
                                      color: Colors.white30,
                                      size: 14,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                  const SizedBox(height: 24),

                  Row(
                    children: [
                      Text(
                        'STATUS STORY',
                        style: GoogleFonts.sora(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white38,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(child: Divider(color: Colors.white12)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_storyError != null)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.red.shade900.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        _storyError!,
                        style: GoogleFonts.sora(color: Colors.red.shade300),
                      ),
                    ),
                  if (_openingStory)
                    Container(
                      height: 200,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(
                            color: Color(0xFF6BBF7A),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Computing analytics…',
                            style: GoogleFonts.sora(color: Colors.white38),
                          ),
                          Text(
                            'This may take a moment on first run',
                            style: GoogleFonts.sora(
                              fontSize: 12,
                              color: Colors.white24,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _openingStory ? null : _openWrappedStory,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1A5276), Color(0xFF2D8B4E)],
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          _openingStory
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.2,
                                  ),
                                )
                              : const Icon(
                                  Icons.auto_awesome_rounded,
                                  color: Colors.white,
                                ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _openingStory
                                      ? 'Building your status update...'
                                      : 'Status Update Available!',
                                  style: GoogleFonts.sora(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  _openingStory
                                      ? 'Calculating every trip analytic first'
                                      : 'Open a scrollable story with all analytics',
                                  style: GoogleFonts.sora(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.arrow_forward_ios_rounded,
                            color: Colors.white54,
                            size: 16,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Text(
      label,
      style: GoogleFonts.sora(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.white38,
        letterSpacing: 2,
      ),
    );
  }

  Widget _dataChip(IconData icon, String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white38, size: 14),
        const SizedBox(width: 5),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: GoogleFonts.sora(
                fontSize: 9,
                color: Colors.white30,
                letterSpacing: 1,
              ),
            ),
            Text(
              value,
              style: GoogleFonts.sora(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _promptAddCollaborator(BuildContext ctx) {
    final ctrl = TextEditingController();
    showDialog(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF12122A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Add Collaborator',
          style: GoogleFonts.sora(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: GoogleFonts.sora(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Name',
            hintStyle: GoogleFonts.sora(color: Colors.white38),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF2E86C1)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(
              'Cancel',
              style: GoogleFonts.sora(color: Colors.white38),
            ),
          ),
          TextButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                setState(() => _collaborators.add(name));
              }
              Navigator.pop(dCtx);
            },
            child: Text(
              'Add',
              style: GoogleFonts.sora(color: Color(0xFF2E86C1)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _gradientHero() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A5276), Color(0xFF2D8B4E)],
        ),
      ),
      child: const Center(
        child: Icon(Icons.explore_rounded, color: Colors.white30, size: 80),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final List<Map<String, dynamic>> trips;
  final VoidCallback onTripsChanged;

  const _EmptyState({required this.trips, required this.onTripsChanged});

  @override
  Widget build(BuildContext context) {
    if (trips.isEmpty) {
      return const _DefaultEmptyState();
    }
    return _QuickActionsState(trips: trips);
  }
}

class _QuickActionsState extends StatelessWidget {
  final List<Map<String, dynamic>> trips;

  const _QuickActionsState({required this.trips});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            alignment: WrapAlignment.start,
            children: [
              for (final trip in trips) _BigSquareButton(tripData: trip),
            ],
          ),
        ),
      ),
    );
  }
}

class _DefaultEmptyState extends StatelessWidget {
  const _DefaultEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 140,
            height: 140,
            decoration: BoxDecoration(
              color: const Color(0xFFF2F2F2),
              borderRadius: BorderRadius.circular(36),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: 28,
                  left: 38,
                  child: Icon(
                    Icons.location_on_rounded,
                    size: 18,
                    color: Colors.grey.shade300,
                  ),
                ),
                Positioned(
                  top: 36,
                  right: 34,
                  child: Icon(
                    Icons.location_on_rounded,
                    size: 12,
                    color: Colors.grey.shade200,
                  ),
                ),
                Positioned(
                  bottom: 34,
                  right: 36,
                  child: Icon(
                    Icons.location_on_rounded,
                    size: 14,
                    color: Colors.grey.shade300,
                  ),
                ),
                CustomPaint(size: const Size(70, 70), painter: _RoutePainter()),
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.map_rounded,
                    size: 26,
                    color: Colors.grey.shade400,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'No trips yet',
            style: GoogleFonts.sora(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF2E86C1),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap + to create your first trip',
            style: GoogleFonts.sora(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: const Color(0xFFD6E8F0),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoutePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD8D8D8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final path = ui.Path()
      ..moveTo(size.width * 0.15, size.height * 0.25)
      ..quadraticBezierTo(
        size.width * 0.4,
        size.height * 0.05,
        size.width * 0.5,
        size.height * 0.45,
      )
      ..quadraticBezierTo(
        size.width * 0.6,
        size.height * 0.85,
        size.width * 0.85,
        size.height * 0.65,
      );

    const dash = 4.0;
    const gap = 4.0;

    for (final m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        final e = (d + dash).clamp(0, m.length);
        canvas.drawPath(m.extractPath(d, e.toDouble()), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ═══════════════════════════════════════════════
// Trip Wrapped — full-screen story view
// ═══════════════════════════════════════════════

// ─── Story slide data ─────────────────────────────────────────────────────────
class _SlideInfo {
  final String label;
  final Widget content;
  const _SlideInfo({required this.label, required this.content});
}

// ─── Photo carousel sub-widget (owns its own index state) ─────────────────────
class _StoryPhotoCarousel extends StatefulWidget {
  final List<Map<String, dynamic>> photos;
  const _StoryPhotoCarousel({required this.photos});
  @override
  State<_StoryPhotoCarousel> createState() => _StoryPhotoCarouselState();
}

class _StoryPhotoCarouselState extends State<_StoryPhotoCarousel> {
  int _idx = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) return const SizedBox();
    final p = widget.photos[_idx];
    final path = p['path'] as String;
    final name = p['name'] as String? ?? '';
    final timestamp = p['timestamp'] as String?;
    final score = p['aesthetic_score'];

    String dateStr = '';
    if (timestamp != null) {
      try {
        final dt = DateTime.parse(timestamp);
        dateStr =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      } catch (_) {
        dateStr = timestamp;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.file(
            File(path),
            width: double.infinity,
            height: 320,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              height: 320,
              color: Colors.grey.shade900,
              child: const Center(
                child: Icon(
                  Icons.broken_image,
                  color: Colors.white38,
                  size: 48,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (name.isNotEmpty)
                    Text(
                      name,
                      style: GoogleFonts.sora(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (dateStr.isNotEmpty)
                    Text(
                      dateStr,
                      style: GoogleFonts.sora(
                        fontSize: 12,
                        color: Colors.white54,
                      ),
                    ),
                  if (score != null)
                    Text(
                      'Score: ${(score as num).toStringAsFixed(3)}',
                      style: GoogleFonts.sora(
                        fontSize: 12,
                        color: const Color(0xFF6BBF7A),
                      ),
                    ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: _idx > 0 ? () => setState(() => _idx--) : null,
                  icon: const Icon(Icons.arrow_back_ios_rounded, size: 18),
                  color: Colors.white,
                  disabledColor: Colors.white24,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '${_idx + 1}/${widget.photos.length}',
                    style: GoogleFonts.sora(
                      fontSize: 13,
                      color: Colors.white54,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _idx < widget.photos.length - 1
                      ? () => setState(() => _idx++)
                      : null,
                  icon: const Icon(Icons.arrow_forward_ios_rounded, size: 18),
                  color: Colors.white,
                  disabledColor: Colors.white24,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Story view ───────────────────────────────────────────────────────────────
class _TripWrappedStory extends StatefulWidget {
  final String tripName;
  final Map<String, dynamic> analytics;

  const _TripWrappedStory({required this.tripName, required this.analytics});

  @override
  State<_TripWrappedStory> createState() => _TripWrappedStoryState();
}

class _TripWrappedStoryState extends State<_TripWrappedStory> {
  late final PageController _pageCtrl;
  late final List<_SlideInfo> _slides;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    _slides = _makeSlides();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _sec(String k) {
    final v = widget.analytics[k];
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.map((a, b) => MapEntry(a.toString(), b));
    return {};
  }

  List<Map<String, dynamic>> _extractLocations() {
    final locs = <Map<String, dynamic>>[];
    final mapData = widget.analytics['map_of_photos'] as Map?;
    if (mapData == null) return locs;
    for (final p in (mapData['points'] as List? ?? [])) {
      locs.add({
        'latitude': p['lat'],
        'longitude': p['lon'],
        'arrival': p['ts'],
      });
    }
    return locs;
  }

  List<Map<String, dynamic>> _extractKeyPhotos() {
    final photos = <Map<String, dynamic>>[];
    final kpData = widget.analytics['key_photos'] as Map?;
    if (kpData == null) return photos;
    for (final photo in (kpData['photos'] as List? ?? [])) {
      photos.add({
        'path': photo['path'],
        'name': photo['path'].toString().split(RegExp(r'[\\/]')).last,
        'timestamp': photo['timestamp'],
        'latitude': null,
        'longitude': null,
        'aesthetic_score': photo['score'],
      });
    }
    return photos;
  }

  List<_SlideInfo> _makeSlides() {
    final locs = _extractLocations();
    final keyPhotos = _extractKeyPhotos();
    return [
      _SlideInfo(label: 'Overview', content: _buildIntroSlide()),
      if (locs.isNotEmpty || keyPhotos.isNotEmpty)
        _SlideInfo(label: 'Route', content: _buildRouteSlide(locs, keyPhotos)),
      _SlideInfo(
        label: 'Map',
        content: MapOfPhotosCard(data: _sec('map_of_photos')),
      ),
      _SlideInfo(
        label: 'Inner Circle',
        content: InnerCircleCard(data: _sec('inner_circle')),
      ),
      _SlideInfo(
        label: 'Food Map',
        content: FoodMapCard(data: _sec('food_map')),
      ),
      _SlideInfo(
        label: 'Growth',
        content: PhotographersGrowthCard(data: _sec('photographers_growth')),
      ),
      _SlideInfo(
        label: 'Emotions',
        content: EmotionalTimelineCard(data: _sec('emotional_timeline')),
      ),
      _SlideInfo(
        label: 'Footprint',
        content: WorldFootprintCard(data: _sec('world_footprint')),
      ),
      _SlideInfo(
        label: 'Pets',
        content: PetReportCard(data: _sec('pet_report_card')),
      ),
      _SlideInfo(
        label: 'Sunsets',
        content: ChasingSunsetsCard(data: _sec('chasing_sunsets')),
      ),
      _SlideInfo(
        label: 'Time Machine',
        content: TimeMachineCard(data: _sec('time_machine')),
      ),
      _SlideInfo(
        label: 'Heatmap',
        content: PhotoTimelineHeatmapCard(data: _sec('photo_timeline_heatmap')),
      ),
      _SlideInfo(
        label: 'Hours',
        content: HoursOfDayWheelCard(data: _sec('hours_of_day_wheel')),
      ),
      _SlideInfo(
        label: 'Stats',
        content: TripStatsCard(data: _sec('trip_stats')),
      ),
      _SlideInfo(
        label: 'Camera',
        content: CameraUsageCard(data: _sec('camera_usage')),
      ),
      _SlideInfo(
        label: 'Locations',
        content: TopLocationsCard(data: _sec('top_locations')),
      ),
      _SlideInfo(
        label: 'Duration',
        content: TripDurationRankingCard(data: _sec('trip_duration_ranking')),
      ),
      _SlideInfo(
        label: 'DNA',
        content: PhotographyDNACard(data: _sec('photography_dna')),
      ),
      _SlideInfo(
        label: 'Night Owl',
        content: NightOwlReportCard(data: _sec('night_owl')),
      ),
      _SlideInfo(
        label: 'Key Photos',
        content: KeyPhotosCard(data: _sec('key_photos')),
      ),
      _SlideInfo(
        label: 'Special',
        content: BenAharonSpecialCard(data: _sec('ben_aharon_special')),
      ),
    ];
  }

  void _goNext() {
    if (_current < _slides.length - 1) {
      _pageCtrl.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  void _goPrev() {
    if (_current > 0) {
      _pageCtrl.previousPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050510),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (d) {
          final w = MediaQuery.of(context).size.width;
          if (d.globalPosition.dx < w * 0.3) {
            _goPrev();
          } else if (d.globalPosition.dx > w * 0.7) {
            _goNext();
          }
        },
        child: Stack(
          children: [
            // ── Foreground content ──────────────────────────────────────────
            Column(
              children: [
                // Story header: progress bars + title
                Container(
                  color: const Color(0xFF050510),
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      children: [
                        // Segmented progress bars
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                          child: Row(
                            children: List.generate(_slides.length, (i) {
                              return Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 1.5,
                                  ),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: i <= _current
                                          ? Colors.white
                                          : Colors.white.withValues(
                                              alpha: 0.22,
                                            ),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                        // Close + title row
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () => Navigator.pop(context),
                                icon: Container(
                                  padding: const EdgeInsets.all(7),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.close_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      widget.tripName,
                                      style: GoogleFonts.sora(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      '${_slides[_current].label}  •  ${_current + 1} / ${_slides.length}',
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
                        ),
                      ],
                    ),
                  ),
                ),
                // Slide content
                Expanded(
                  child: PageView.builder(
                    controller: _pageCtrl,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) => setState(() => _current = i),
                    itemCount: _slides.length,
                    itemBuilder: (_, i) => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
                      child: _slides[i].content,
                    ),
                  ),
                ),
              ],
            ),
            // ── Left / right tap zones (on top) ─────────────────────────────
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: MediaQuery.of(context).size.width * 0.3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _goPrev,
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: MediaQuery.of(context).size.width * 0.3,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _goNext,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroSlide() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF18314F), Color(0xFF174A3D)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'YOUR TRIP STORY',
            style: GoogleFonts.sora(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white38,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            widget.tripName,
            style: GoogleFonts.sora(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Tap the right side of the screen to advance to the next analytics card.\nTap the left side to go back.',
            style: GoogleFonts.sora(
              fontSize: 14,
              color: Colors.white70,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _infoTile(
                  Icons.chevron_left_rounded,
                  'Tap left',
                  'Previous slide',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _infoTile(
                  Icons.chevron_right_rounded,
                  'Tap right',
                  'Next slide',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoTile(IconData icon, String title, String sub) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 20),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.sora(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white70,
                ),
              ),
              Text(
                sub,
                style: GoogleFonts.sora(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRouteSlide(
    List<Map<String, dynamic>> locs,
    List<Map<String, dynamic>> photos,
  ) {
    final routePoints = <LatLng>[];
    for (final loc in locs) {
      routePoints.add(
        LatLng(
          (loc['latitude'] as num).toDouble(),
          (loc['longitude'] as num).toDouble(),
        ),
      );
    }

    LatLng center = LatLng(37.5665, 126.978);
    if (routePoints.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      for (final p in routePoints) {
        latSum += p.latitude;
        lngSum += p.longitude;
      }
      center = LatLng(latSum / routePoints.length, lngSum / routePoints.length);
    }

    final markers = <Marker>[];
    for (int i = 0; i < locs.length; i++) {
      final loc = locs[i];
      final lat = (loc['latitude'] as num).toDouble();
      final lng = (loc['longitude'] as num).toDouble();
      final arrival = loc['arrival'] as String?;
      String dateLabel = '${i + 1}';
      if (arrival != null) {
        try {
          final dt = DateTime.parse(arrival);
          dateLabel = '${dt.month}/${dt.day}';
        } catch (_) {}
      }
      markers.add(
        Marker(
          point: LatLng(lat, lng),
          width: 52,
          height: 52,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF2E86C1), Color(0xFF6BBF7A)],
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.location_on_rounded,
                  color: Colors.white,
                  size: 16,
                ),
              ),
              Text(
                dateLabel,
                style: GoogleFonts.sora(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ROUTE + HIGHLIGHTS',
          style: GoogleFonts.sora(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white38,
            letterSpacing: 1.8,
          ),
        ),
        const SizedBox(height: 14),
        if (routePoints.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: 280,
              child: FlutterMap(
                options: MapOptions(initialCenter: center, initialZoom: 7),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.quemory.app',
                  ),
                  if (routePoints.length >= 2)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: routePoints,
                          color: const Color(0xFF2E86C1),
                          strokeWidth: 3,
                        ),
                      ],
                    ),
                  MarkerLayer(markers: markers),
                ],
              ),
            ),
          ),
        if (photos.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'HIGHLIGHTS',
            style: GoogleFonts.sora(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white38,
              letterSpacing: 1.8,
            ),
          ),
          const SizedBox(height: 10),
          _StoryPhotoCarousel(photos: photos),
        ],
      ],
    );
  }
}
