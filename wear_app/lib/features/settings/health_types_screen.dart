import 'package:flutter/material.dart';
import 'package:signals/signals_flutter.dart';
import 'package:wear_app/gen/wearlink.pb.dart';

/// Health data types available for sync to iPhone.
/// Matches HealthSample.Type in wearlink.proto.
class HealthTypeOption {
  final String label;
  final String subtitle;
  final IconData icon;
  final HealthSample_Type protoType;
  final Signal<bool> enabled;

  const HealthTypeOption({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.protoType,
    required this.enabled,
  });
}

/// Screen to configure which health data types are pushed to the iPhone.
/// Uses large toggle tokens (custom switch) in tappable gradient rows.
class HealthTypesScreen extends StatefulWidget {
  final List<HealthTypeOption> options;

  const HealthTypesScreen({super.key, required this.options});

  @override
  State<HealthTypesScreen> createState() => _HealthTypesScreenState();
}

class _HealthTypesScreenState extends State<HealthTypesScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      appBar: AppBar(
        title: const Text('Health Sync'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          itemCount: widget.options.length,
          itemBuilder: (context, index) {
            final opt = widget.options[index];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SignalBuilder(
                builder: (context) {
                  final isOn = opt.enabled.value;
                  return _HealthTypeTile(
                    option: opt,
                    isOn: isOn,
                    onToggle: () => opt.enabled.value = !isOn,
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A single health type row with large toggle token.
///
/// - 24x24 icon in 44x44 circular container
/// - Label + subtitle with FittedBox auto-sizing
/// - Custom large toggle switch (48x28)
/// - Gradient card background with subtle border
class _HealthTypeTile extends StatelessWidget {
  final HealthTypeOption option;
  final bool isOn;
  final VoidCallback onToggle;

  const _HealthTypeTile({
    required this.option,
    required this.isOn,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              isOn
                  ? const Color(0xFF14E5B3).withValues(alpha: 0.1)
                  : const Color(0xFF0D0D1A),
              const Color(0xFF151525),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isOn
                ? const Color(0xFF14E5B3).withValues(alpha: 0.3)
                : Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              // Icon in 44x44 circular container
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      isOn
                          ? const Color(0xFF14E5B3).withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  option.icon,
                  size: 24,
                  color: isOn ? const Color(0xFF14E5B3) : Colors.grey,
                ),
              ),
              const SizedBox(width: 12),
              // Label + subtitle
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        option.label,
                        style: TextStyle(
                          color: isOn ? Colors.white : Colors.grey,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        option.subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Large custom toggle token
              _ToggleToken(value: isOn, onChanged: (_) => onToggle()),
            ],
          ),
        ),
      ),
    );
  }
}

/// A large custom toggle switch (48x28) with smooth animation.
/// Uses AnimatedContainer for the track and AnimatedAlign for the thumb.
class _ToggleToken extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleToken({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 48,
        height: 28,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: value
              ? const Color(0xFF14E5B3)
              : Colors.white.withValues(alpha: 0.1),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 200),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 24,
                height: 24,
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: value
                      ? [
                          BoxShadow(
                            color: const Color(0xFF14E5B3).withValues(alpha: 0.4),
                            blurRadius: 4,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
