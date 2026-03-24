import 'package:flutter/material.dart';
import 'orion_rage_click_tracker.dart';

/// Widget wrapper that detects rage clicks across the entire app.
/// 
/// Wrap your MaterialApp or root widget with this to enable rage click tracking:
/// 
/// ```dart
/// OrionRageClickDetector(
///   child: MaterialApp(
///     // ...
///   ),
/// )
/// ```
/// 
/// Or with custom configuration:
/// 
/// ```dart
/// OrionRageClickDetector(
///   config: RageClickConfig(
///     minTapCount: 4,
///     timeWindowMs: 1200,
///     radiusDp: 60.0,
///   ),
///   child: MaterialApp(
///     // ...
///   ),
/// )
/// ```
class OrionRageClickDetector extends StatefulWidget {
  /// The child widget (usually MaterialApp)
  final Widget child;

  /// Rage click detection configuration
  final RageClickConfig? config;

  /// Callback when a rage click is detected (optional)
  final void Function(RageClick)? onRageClick;

  /// Whether to show visual feedback on rage click (debug only)
  final bool showDebugOverlay;

  const OrionRageClickDetector({
    super.key,
    required this.child,
    this.config,
    this.onRageClick,
    this.showDebugOverlay = false,
  });

  @override
  State<OrionRageClickDetector> createState() => _OrionRageClickDetectorState();
}

class _OrionRageClickDetectorState extends State<OrionRageClickDetector> {
  // For debug overlay
  Offset? _lastRageClickPosition;
  bool _showOverlay = false;

  @override
  void initState() {
    super.initState();
    
    // Apply configuration if provided
    if (widget.config != null) {
      OrionRageClickTracker.configure(widget.config!);
    }
  }

  @override
  void didUpdateWidget(OrionRageClickDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // Update configuration if changed
    if (widget.config != oldWidget.config && widget.config != null) {
      OrionRageClickTracker.configure(widget.config!);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    // Record tap at logical pixel position
    final detected = OrionRageClickTracker.recordTap(
      event.localPosition.dx,
      event.localPosition.dy,
    );

    if (detected) {
      // Get the detected rage click
      final screen = OrionRageClickTracker.currentScreen ?? 'Unknown';
      final clicks = OrionRageClickTracker.getRageClicksForScreen(screen);
      
      if (clicks.isNotEmpty) {
        final latestClick = clicks.last;
        
        // Call callback if provided
        widget.onRageClick?.call(latestClick);

        // Show debug overlay if enabled
        if (widget.showDebugOverlay) {
          _showRageClickOverlay(event.localPosition);
        }
      }
    }
  }

  void _showRageClickOverlay(Offset position) {
    setState(() {
      _lastRageClickPosition = position;
      _showOverlay = true;
    });

    // Hide after 1 second
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() {
          _showOverlay = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      child: widget.child,
    );

    // Add debug overlay if enabled
    if (widget.showDebugOverlay && _showOverlay && _lastRageClickPosition != null) {
      child = Stack(
        children: [
          child,
          Positioned(
            left: _lastRageClickPosition!.dx - 30,
            top: _lastRageClickPosition!.dy - 30,
            child: IgnorePointer(
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.red, width: 2),
                ),
                child: const Center(
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.red,
                    size: 24,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return child;
  }
}

/// Extension for easy integration with MaterialApp
extension OrionRageClickExtension on Widget {
  /// Wrap this widget with rage click detection
  Widget withRageClickDetection({
    RageClickConfig? config,
    void Function(RageClick)? onRageClick,
    bool showDebugOverlay = false,
  }) {
    return OrionRageClickDetector(
      config: config,
      onRageClick: onRageClick,
      showDebugOverlay: showDebugOverlay,
      child: this,
    );
  }
}
