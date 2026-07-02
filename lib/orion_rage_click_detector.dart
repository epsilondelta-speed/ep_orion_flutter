import 'package:flutter/material.dart';
import 'orion_logger.dart';
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

  /// Circuit breaker: if our own detection code ever throws unexpectedly,
  /// flip this flag and become a transparent no-op for all future taps.
  /// This prevents any Orion bug from affecting the host app's gesture
  /// pipeline. The flag is per-widget-instance, so a hot-reload or widget
  /// rebuild clears it.
  bool _circuitBroken = false;

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
    // ✅ Circuit breaker: any prior exception in our detection code makes
    //    all future taps instant no-ops — zero overhead on the gesture path.
    if (_circuitBroken) return;

    try {
      final detected = OrionRageClickTracker.recordTap(
        event.localPosition.dx,
        event.localPosition.dy,
      );

      if (detected) {
        final screen = OrionRageClickTracker.currentScreen ?? 'Unknown';
        final clicks = OrionRageClickTracker.getRageClicksForScreen(screen);

        if (clicks.isNotEmpty) {
          final latestClick = clicks.last;

          // ✅ Guard the customer callback in its own try-catch.
          //    If their onRageClick throws, that's their bug — log it and
          //    continue rather than propagating it into our circuit breaker
          //    or up into Flutter's gesture pipeline.
          try {
            widget.onRageClick?.call(latestClick);
          } catch (e) {
            orionPrint('[OrionRageClick] onRageClick callback threw: $e');
          }

          if (widget.showDebugOverlay) {
            _showRageClickOverlay(event.localPosition);
          }
        }
      }
    } catch (e) {
      // ✅ Unexpected exception in our own detection logic: break the circuit.
      //    Future taps bail out at the top of this method — no further work.
      _circuitBroken = true;
      orionPrint('[OrionRageClick] circuit broken, rage click tracking '
          'disabled for this instance: $e');
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

  /// Feed depth-0 (outermost scrollable) scroll positions to the tracker.
  ///
  /// ScrollNotifications bubble up from every descendant scrollable, so this
  /// captures scroll state app-wide with zero client integration. depth == 0
  /// filters out nested scrollables (e.g. a horizontal carousel inside a
  /// vertical list) so the offset always reflects the page-level scroll.
  ///
  /// Only vertical axis is tracked for v1 — vertical scroll dominates the
  /// "content moved under the tap position" problem on listing/detail pages.
  bool _onScrollNotification(ScrollNotification notification) {
    try {
      if (notification.depth == 0 &&
          notification.metrics.axis == Axis.vertical) {
        OrionRageClickTracker.updateScrollOffset(
          notification.metrics.pixels,
          notification.metrics.maxScrollExtent,
        );
      }
    } catch (_) {
      // Never let scroll observation interfere with the app's scrolling.
    }
    return false; // don't consume — let the notification keep bubbling
  }

  @override
  Widget build(BuildContext context) {
    Widget child = NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        child: widget.child,
      ),
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