import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'dart:io';

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
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          _trips.clear();
          for (final t in data) {
            _trips.add({
              'id': t['id'],
              'name': t['name'],
              'notes': t['notes'],
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
        await _loadTrips();
      }
    } catch (e) {
      debugPrint('Detect trips error: $e');
    }
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
                                                if (selectedFolder != null)
                                                  'folder': selectedFolder,
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
                                                  'notes': data['notes'],
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
  final String label;
  final int tripId;
  final String? imagePath;

  const _BigSquareButton({
    required this.label,
    required this.tripId,
    this.imagePath,
  });

  @override
  State<_BigSquareButton> createState() => _BigSquareButtonState();
}

class _BigSquareButtonState extends State<_BigSquareButton> {
  void _share() {
    debugPrint('Shared!');
  }

  Future<List<Map<String, dynamic>>> _loadLocations() async {
    try {
      final file = File(r'D:\Proj\QueMory2\locations.json');
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final List<dynamic> data = json.decode(jsonStr);
        return data.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('Error loading locations: $e');
    }
    return [];
  }

  void _showTripPanel(BuildContext context) async {
    final locations = await _loadLocations();

    List<Map<String, dynamic>> curatedPhotos = [];
    if (widget.tripId >= 0) {
      try {
        final response = await http.get(
          Uri.parse('http://localhost:8000/trips/${widget.tripId}/photos'),
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as List;
          curatedPhotos = data.cast<Map<String, dynamic>>();
        }
      } catch (e) {
        debugPrint('Load photos error: $e');
      }
    }

    LatLng center = LatLng(37.5665, 126.978); // fallback
    List<Marker> markers = [];

    if (locations.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      for (final loc in locations) {
        latSum += loc['latitude'];
        lngSum += loc['longitude'];
      }
      center = LatLng(latSum / locations.length, lngSum / locations.length);

      markers = locations.map((loc) {
        return Marker(
          point: LatLng(loc['latitude'], loc['longitude']),
          width: 36,
          height: 36,
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF2E86C1), Color(0xFF6BBF7A)],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1A5276).withValues(alpha: 0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(
              Icons.location_on_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
        );
      }).toList();
    }

    if (!context.mounted) return;

    showGeneralDialog(
      context: context,
      barrierLabel: 'Trip Panel',
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 350),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 720,
              constraints: const BoxConstraints(maxHeight: 850),
              padding: const EdgeInsets.all(40),
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
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      widget.label,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.sora(
                        fontSize: 52,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF1A5276),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 300,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: FlutterMap(
                          options: MapOptions(
                            initialCenter: center,
                            initialZoom: 7,
                          ),
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
                    const SizedBox(height: 20),
                    Text(
                      'Description:',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.sora(
                        fontSize: 30,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF2D8B4E),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 110,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          'We kicked off bright and early from Seoul Station, grabbing hot cans of coffee from a vending machine before boarding. '
                          'The countryside rolled past the window — terraced rice paddies, pine-covered ridgelines, and the occasional cluster of red-roofed farmhouses. '
                          'Arrived in Gyeongju around noon and spent the afternoon wandering among ancient royal tombs. '
                          'The grassy burial mounds felt almost alive in the afternoon light. '
                          'Dinner was a stone-bowl bibimbap so good we ordered a second round. '
                          'Day two we rented bikes and circled Bomun Lake as cherry blossoms drifted across the path like pink snow. '
                          'The local night market was a blur of tteokbokki, fish cakes, and street-side karaoke booths. '
                          'By day three the group was fully in sync — slower mornings, longer detours, and zero complaints.',
                          style: GoogleFonts.sora(
                            fontSize: 14,
                            color: Colors.black87,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Key Photos:',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.sora(
                        fontSize: 30,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF2D8B4E),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: curatedPhotos.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: Center(
                                child: Text(
                                  'Loading curated photos...',
                                  style: GoogleFonts.sora(
                                    fontSize: 14,
                                    color: Colors.grey.shade500,
                                  ),
                                ),
                              ),
                            )
                          : Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: curatedPhotos.map((photo) {
                                final path = photo['path'] as String;
                                final name = photo['name'] as String;
                                return ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.file(
                                    File(path),
                                    width: 180,
                                    height: 180,
                                    fit: BoxFit.cover,
                                    errorBuilder: (ctx, err, stack) =>
                                        Container(
                                          width: 180,
                                          height: 180,
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade200,
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
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
                    const SizedBox(height: 20),
                    Text(
                      'Key Data:',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.sora(
                        fontSize: 30,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF2D8B4E),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 110,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          'Duration: 7 days  •  Dates: Apr 3 – Apr 9, 2026\n'
                          'Destinations: Seoul, Gyeongju, Busan, Jeju Island\n'
                          'Total distance covered: ~1,240 km\n'
                          'Flights: ICN → CJU (return)  •  Train: KTX Seoul–Busan x2\n'
                          'Accommodation: 2 nights guesthouse, 3 nights hotel, 2 nights Airbnb\n'
                          'Total budget: ₩620,000 (~\$465 USD)  •  Avg per day: ₩88,500\n'
                          'Photos taken: 847  •  Videos: 23  •  Favourites: 112\n'
                          'Weather: Mostly sunny, one rainy afternoon in Busan  •  High: 19°C  •  Low: 8°C\n'
                          'Group size: 4 people  •  Languages needed: Korean, basic English\n'
                          'SIM card: KT data-only eSIM, 10 GB — used 7.2 GB',
                          style: GoogleFonts.sora(
                            fontSize: 14,
                            color: Colors.black87,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Collaborators:',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.sora(
                        fontSize: 30,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF2D8B4E),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 110,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F5F5),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          '• Sofia Nakamura\n'
                          '• Luca Ferreira\n'
                          '• Aisha Okonkwo',
                          style: GoogleFonts.sora(
                            fontSize: 15,
                            color: Colors.black87,
                            height: 2.0,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).push(
                          PageRouteBuilder(
                            opaque: true,
                            pageBuilder: (_, __, ___) => _TripWrappedStory(
                              tripName: widget.label,
                              locations: locations,
                              keyPhotos: curatedPhotos,
                            ),
                            transitionsBuilder: (_, anim, __, child) {
                              return FadeTransition(
                                opacity: anim,
                                child: child,
                              );
                            },
                            transitionDuration: const Duration(
                              milliseconds: 400,
                            ),
                          ),
                        );
                      },
                      child: Text(
                        '>>> Status Update is Available!',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.sora(
                          fontSize: 30,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF6BBF7A),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 50),
                      child: SizedBox(
                        width: 220,
                        height: 60,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: const LinearGradient(
                              colors: [Color(0xFF2E86C1), Color(0xFF6BBF7A)],
                            ),
                          ),
                          child: ElevatedButton(
                            onPressed: _share,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Share',
                              style: GoogleFonts.sora(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Center(
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Color(0xFFE0E0E0)),
                        ),
                        child: const Icon(
                          Icons.image_outlined,
                          size: 28,
                          color: Color(0xFFBDBDBD),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );

        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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
              child: widget.imagePath != null
                  ? Image.file(
                      File(widget.imagePath!),
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
                  widget.label,
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
              for (final trip in trips)
                _BigSquareButton(
                  label: trip['name'] as String,
                  tripId: trip['id'] as int,
                ),
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

class _TripWrappedStory extends StatefulWidget {
  final String tripName;
  final List<Map<String, dynamic>> locations;
  final List<Map<String, dynamic>> keyPhotos;

  const _TripWrappedStory({
    required this.tripName,
    required this.locations,
    required this.keyPhotos,
  });

  @override
  State<_TripWrappedStory> createState() => _TripWrappedStoryState();
}

class _TripWrappedStoryState extends State<_TripWrappedStory>
    with TickerProviderStateMixin {
  int _page = 0;
  static const _totalPages = 2;
  int _photoIndex = 0;

  late final AnimationController _fadeController;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnim = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  void _advance() {
    if (_page + 1 >= _totalPages) {
      Navigator.of(context).pop();
      return;
    }
    _fadeController.reverse().then((_) {
      setState(() => _page++);
      _fadeController.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _advance,
        child: Column(
          children: [
            // Progress bars
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: List.generate(_totalPages, (i) {
                    return Expanded(
                      child: Container(
                        margin: EdgeInsets.only(
                          right: i < _totalPages - 1 ? 6 : 0,
                        ),
                        height: 3,
                        decoration: BoxDecoration(
                          color: i <= _page
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
            // Page content
            Expanded(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: _page == 0 ? _buildIntroPage() : _buildRoutePage(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIntroPage() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Here's your\ntrip wrapped.",
              textAlign: TextAlign.center,
              style: GoogleFonts.sora(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.tripName,
              textAlign: TextAlign.center,
              style: GoogleFonts.sora(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF6BBF7A),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoutePage() {
    final photos = widget.keyPhotos;
    final locs = widget.locations;

    // Build route points
    final routePoints = <LatLng>[];
    for (final loc in locs) {
      routePoints.add(
        LatLng(
          (loc['latitude'] as num).toDouble(),
          (loc['longitude'] as num).toDouble(),
        ),
      );
    }

    // Center map
    LatLng center = LatLng(37.5665, 126.978);
    if (routePoints.isNotEmpty) {
      double latSum = 0, lngSum = 0;
      for (final p in routePoints) {
        latSum += p.latitude;
        lngSum += p.longitude;
      }
      center = LatLng(latSum / routePoints.length, lngSum / routePoints.length);
    }

    // Build markers with date labels
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
      children: [
        // Map with route
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
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
        ),
        // Single photo viewer with nav
        if (photos.isNotEmpty)
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _buildPhotoViewer(photos),
            ),
          ),
        if (photos.isEmpty) const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildPhotoViewer(List<Map<String, dynamic>> photos) {
    final photo = photos[_photoIndex];
    final path = photo['path'] as String;
    final name = photo['name'] as String? ?? '';
    final timestamp = photo['timestamp'] as String?;
    final lat = photo['latitude'];
    final lon = photo['longitude'];
    final score = photo['aesthetic_score'];

    String dateStr = '';
    if (timestamp != null) {
      try {
        final dt = DateTime.parse(timestamp);
        dateStr =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}  ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        dateStr = timestamp;
      }
    }

    String coordStr = '';
    if (lat != null && lon != null) {
      coordStr =
          '${(lat as num).toStringAsFixed(4)}, ${(lon as num).toStringAsFixed(4)}';
    }

    return Column(
      children: [
        // Photo
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Image.file(
              File(path),
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
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
        ),
        const SizedBox(height: 12),
        // Metadata
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: GoogleFonts.sora(
                      fontSize: 14,
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
                        color: Colors.white60,
                      ),
                    ),
                  if (coordStr.isNotEmpty)
                    Text(
                      coordStr,
                      style: GoogleFonts.sora(
                        fontSize: 12,
                        color: Colors.white60,
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
            Text(
              '${_photoIndex + 1} / ${photos.length}',
              style: GoogleFonts.sora(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white54,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Nav buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: _photoIndex > 0
                  ? () => setState(() => _photoIndex--)
                  : null,
              icon: const Icon(Icons.arrow_back_ios_rounded, size: 20),
              color: Colors.white,
              disabledColor: Colors.white24,
            ),
            const SizedBox(width: 32),
            IconButton(
              onPressed: _photoIndex < photos.length - 1
                  ? () => setState(() => _photoIndex++)
                  : null,
              icon: const Icon(Icons.arrow_forward_ios_rounded, size: 20),
              color: Colors.white,
              disabledColor: Colors.white24,
            ),
          ],
        ),
      ],
    );
  }
}
