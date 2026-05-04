import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'trips.dart';
import 'query.dart';
import 'wrapped.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 1;

  final List<Widget> _pages = const [
    Scaffold(body: Center(child: Text('Share'))),
    TripsPage(),
    QueryPage(),
    WrappedPage(),
    Scaffold(body: Center(child: Text('Settings'))),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFF0F0F0), width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          selectedItemColor: const Color(0xFF2D8B4E),
          unselectedItemColor: Colors.black,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          selectedLabelStyle: GoogleFonts.sora(
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: GoogleFonts.sora(
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
          onTap: (index) {
            setState(() => _currentIndex = index);
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.upload_rounded),
              label: 'Share',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              label: 'Trips',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.travel_explore_rounded),
              label: 'Query',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.auto_awesome_rounded),
              label: 'Wrapped',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.tune_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
