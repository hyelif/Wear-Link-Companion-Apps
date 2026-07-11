import 'package:flutter/material.dart';

/// Theme colors for the WearLink design system
class WearColors {
  static const Color primaryTeal = Colors.teal;
  static const Color background = Color(0xFF0D0D0D);
  static const Color cardBg = Color(0xFF1A1A2E);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Colors.white70;
}

/// WearCard: A rounded container with a dark background and teal border.
class WearCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  const WearCard({
    super.key,
    required this.child,
    this.radius = 24.0,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: WearColors.cardBg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: WearColors.primaryTeal, width: 1.0),
      ),
      child: child,
    );
  }
}

/// WearActionChip: A pill-shaped teal button.
class WearActionChip extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  const WearActionChip({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: WearColors.primaryTeal,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// WearStatItem: Icon + Value + Label layout for health stats.
class WearStatItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color iconColor;

  const WearStatItem({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.iconColor = WearColors.primaryTeal,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: WearColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              label,
              style: const TextStyle(
                color: WearColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// WearScalingSliver: A wrapper that mimics the scaling effect of a Wear OS ScalingLazyColumn.
/// It scales and fades children based on their distance from the center of the viewport.
class WearScalingSliver extends StatefulWidget {
  final Widget child;

  const WearScalingSliver({super.key, required this.child});

  @override
  State<WearScalingSliver> createState() => _WearScalingSliverState();
}

class _WearScalingSliverState extends State<WearScalingSliver> {
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: Transform.scale(
            scale: 1.0, // In a full implementation, this would depend on scroll offset
            child: Opacity(
              opacity: 1.0, // In a full implementation, this would depend on scroll offset
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

/// WearScreenScaffold: A wrapper with SafeArea, TimeText placeholder, and Vignette fade.
class WearScreenScaffold extends StatelessWidget {
  final Widget body;
  final String? title;

  const WearScreenScaffold({super.key, required this.body, this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearColors.background,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildTimeText(),
                if (title != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(
                      title!,
                      style: const TextStyle(
                        color: WearColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
                Expanded(child: body),
              ],
            ),
          ),
          const WearVignette(),
        ],
      ),
    );
  }

  Widget _buildTimeText() {
    return const Padding(
      padding: EdgeInsets.only(top: 8.0),
      child: Text(
        "12:45", // Placeholder for real time
        style: TextStyle(
          color: WearColors.textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// WearVignette: A dark radial gradient overlay to create a depth effect on the screen edges.
class WearVignette extends StatelessWidget {
  const WearVignette({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [
              Colors.transparent,
              WearColors.background.withValues(alpha: 0.7),
            ],
            stops: const [0.7, 1.0],
          ),
        ),
      ),
    );
  }
}
