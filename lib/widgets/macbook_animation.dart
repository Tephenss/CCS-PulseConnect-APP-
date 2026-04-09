import 'package:flutter/material.dart';
import 'dart:math' as math;

class MacbookAnimation extends StatefulWidget {
  final double scale;
  const MacbookAnimation({super.key, this.scale = 1.0});

  @override
  State<MacbookAnimation> createState() => _MacbookAnimationState();
}

class _MacbookAnimationState extends State<MacbookAnimation> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _rotateX;

  int _currentSlide = 0;
  bool _isInitialStart = true;
  
  final List<Map<String, String>> showcaseSlides = [
    { 'img': 'assets/sample summit/image1.jpg', 'label': 'CCS SUMMIT' },
    { 'img': 'assets/sample GA/image1.jpg', 'label': 'GENERAL ASSEMBLY' },
    { 'img': 'assets/sample exhibit/image1.jpg', 'label': 'CCS EXHIBIT' },
    { 'img': 'assets/sample CV/image1.jpg', 'label': 'COMPANY VISIT' }
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4), // matches 4s openLaptop CSS duration
    )..repeat(reverse: true);
    
    // Animate from -88.5 degrees (closed) to 0 (open) matching openLaptop CSS keyframes
    _rotateX = Tween<double>(begin: -88.5 * math.pi / 180, end: 0.0)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic));

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.forward) {
        if (_isInitialStart) {
          _isInitialStart = false; // Ignore the very first 'forward' when widget mounts
        } else {
          // Whenever it starts opening again (fully closed), swap to the next slide!
          setState(() {
            _currentSlide = (_currentSlide + 1) % showcaseSlides.length;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: widget.scale,
      child: SizedBox(
        width: 310,
        height: 190,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Screen (animated closing/opening lid)
            Positioned(
              bottom: 12, // sits exactly on top of keyboard hinge
              child: AnimatedBuilder(
                animation: _rotateX,
                builder: (context, child) {
                  return Transform(
                    transform: Matrix4.identity()
                      // Replicate transform: perspective(1900px) rotateX(...)
                      ..setEntry(3, 2, 1 / 1900.0)
                      ..rotateX(_rotateX.value),
                    alignment: Alignment.bottomCenter,
                    child: child,
                  );
                },
                child: _buildScreen(),
              ),
            ),
            // Keyboard (static base)
            Positioned(
              bottom: 3, 
              child: _buildKeyboard(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScreen() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 259, // 518/2
          height: 159, // 318/2
          decoration: BoxDecoration(
            color: Colors.black, // Dark/black bezel
            borderRadius: BorderRadius.circular(10), // 20/2
            border: Border.all(color: const Color(0xFFc8cacb), width: 1), // Outer silver border
            // Using a plain background to act as the inner bezel shadow since inset isn't supported natively
          ),
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 13), // Adjusted padding to simulate the thick 10px inner black shadow and 23px bottom

          child: Stack(
            alignment: Alignment.center,
            children: [
              // Inner screen bg
              ClipRRect(
                borderRadius: BorderRadius.circular(6), // 12/2
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      showcaseSlides[_currentSlide]['img']!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFFea580c), Color(0xFF7c2d12)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                      ),
                    ),
                    // Overlay tint (rgba 0,0,0, 0.4)
                    Container(color: Colors.black.withValues(alpha: 0.4)),
                  ],
                ),
              ),
              
              // Text mimicking the CSS text-shadow exactly
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  showcaseSlides[_currentSlide]['label']!,
                  key: ValueKey<int>(_currentSlide),
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Roboto',
                    fontSize: 16, // 32/2
                    fontWeight: FontWeight.w900, // 800-900 extrabold
                    letterSpacing: 1, // Scaled down letterspacing
                    shadows: [
                      Shadow(color: Color(0xCC000000), blurRadius: 5, offset: Offset(0, 2)),
                      Shadow(color: Color(0x66FF6464), blurRadius: 10, offset: Offset(0, 0)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // Header cam / notch (header-cam)
        Positioned(
          top: 5, // 10/2
          left: (259 / 2) - 25,
          child: Container(
            width: 50, // 100/2
            height: 6, // 12/2
            decoration: const BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(3)), // 6/2
            ),
          ),
        ),
        
        // Top hinge line (recreating the screen::before hinge gradient)
        Positioned(
          top: -1, // -3/2
          left: 0,
          child: Container(
            width: 259, // 518/2
            height: 6,  // 12/2
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF979899), Colors.transparent],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
        ),
        
        // Bottom bezel gradient strip (screen::after)
        Positioned(
          bottom: 1, // bottom: 2px / 2
          left: 1,   // left: 2px / 2
          right: 1,
          height: 12, // 24/2
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF272727), Color(0xFF0d0d0d)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKeyboard() {
    return Container(
      width: 310,  // 620/2
      height: 12,  // 24/2
      decoration: BoxDecoration(
        color: const Color(0xFFe2e3e4), // fallback
        gradient: const RadialGradient(
          colors: [Color(0xFFe2e3e4), Color(0xFFa9abac)],
          radius: 2.5,
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(1), // 2/2
          bottom: Radius.circular(6), // 12/2
        ),
        border: const Border(
          top: BorderSide(color: Color(0xFFa0a3a7), width: 0.5), // 1px/2
          left: BorderSide(color: Color(0xFFa0a3a7), width: 1), // 2px/2
          right: BorderSide(color: Color(0xFFa0a3a7), width: 1), // 2px/2
        ),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 30, offset: Offset(0, 15)), // Drop shadow (0 30px 60px rgba(0,0,0,0.8)) scaled
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Middle trackpad notch/lip
          Positioned(
            top: 0,
            child: Container(
              width: 60, // 120/2
              height: 5, // 10/2
              decoration: BoxDecoration(
                color: const Color(0xFFe2e3e4),
                border: Border.all(color: const Color(0xFFbabdbf), width: 1.5), // Simulated inset with border
              ),
            ),
          ),
          // Bottom subtle edge (keyboard::before)
          Positioned(
            bottom: -1, // -2/2
            child: Container(
              width: 20, // 40/2
              height: 1, // 2/2
              decoration: const BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(1.5)),
                boxShadow: [
                  BoxShadow(color: Color(0xFF272727), offset: Offset(-135, 0)), // -270/2
                  BoxShadow(color: Color(0xFF272727), offset: Offset(125, 0)),  // 250/2
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
