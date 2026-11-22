// Bottom navigation of the five main screens (76px, as the mockups).

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

class NavItem {
  const NavItem(this.label, this.icon);
  final String label;
  final IconData icon;
}

const mainNavItems = [
  NavItem('Panel', Icons.dashboard_outlined),
  NavItem('Agentes', Icons.sort),
  NavItem('Hosts', Icons.dns_outlined),
  NavItem('Buzón', Icons.inbox_outlined),
  NavItem('Ajustes', Icons.settings_outlined),
];

class AppBottomNav extends StatelessWidget {
  const AppBottomNav({super.key, required this.index, required this.onTap, this.items = mainNavItems});
  final int index;
  final ValueChanged<int> onTap;
  final List<NavItem> items;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Semantics(
      container: true,
      label: 'Principal',
      child: Container(
        height: 76 + bottomInset,
        padding: EdgeInsets.only(bottom: 8 + bottomInset),
        decoration: BoxDecoration(
          color: AppColors.navBg,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            for (final (i, item) in items.indexed)
              Expanded(
                child: Semantics(
                  container: true,
                  selected: i == index,
                  button: true,
                  label: item.label,
                  excludeSemantics: true,
                  child: InkWell(
                    onTap: () => onTap(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(item.icon, size: 22, color: i == index ? AppColors.accent : AppColors.muted),
                        const SizedBox(height: 4),
                        Text(
                          item.label,
                          style: AppFonts.inter(
                            size: 11,
                            weight: i == index ? FontWeight.w600 : FontWeight.w400,
                            color: i == index ? AppColors.accent : AppColors.muted,
                          ),
                        ),
                      ],
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
