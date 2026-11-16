// Folder browser of a host: walk the directory tree (up to `/`) and pick a
// project folder. Pops with the chosen absolute path.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/contracts.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class FolderBrowserScreen extends ConsumerStatefulWidget {
  const FolderBrowserScreen({
    super.key,
    required this.hostId,
    this.initialPath = '',
  });
  final String hostId;

  /// Absolute path to start in; empty = the home directory.
  final String initialPath;

  @override
  ConsumerState<FolderBrowserScreen> createState() =>
      _FolderBrowserScreenState();
}

class _FolderBrowserScreenState extends ConsumerState<FolderBrowserScreen> {
  DirListing? _listing;
  String? _error;
  bool _loading = true;
  bool _hidden = false;
  int _seq = 0;
  final _crumbs = ScrollController();

  @override
  void initState() {
    super.initState();
    _load(widget.initialPath);
  }

  @override
  void dispose() {
    _crumbs.dispose();
    super.dispose();
  }

  Future<void> _load(String path) async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await ref
          .read(sessionsRepositoryProvider)
          .listDir(widget.hostId, path, hidden: _hidden);
      if (!mounted || seq != _seq) return;
      setState(() {
        _listing = l;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_crumbs.hasClients) {
          _crumbs.jumpTo(_crumbs.position.maxScrollExtent);
        }
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      final msg = e is ListDirException
          ? e.message
          : 'No se pudo leer la carpeta';
      setState(() {
        _loading = false;
        _error = msg;
      });
      if (_listing != null) showToast(context, '$msg: ${_shown(path)}');
    }
  }

  String _shown(String p) => p.isEmpty ? 'Inicio' : p;

  static String _join(String dir, String name) =>
      dir == '/' ? '/$name' : '$dir/$name';

  static String _parent(String p) {
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  void _toggleHidden() {
    setState(() => _hidden = !_hidden);
    _load(_listing?.path ?? widget.initialPath);
  }

  @override
  Widget build(BuildContext context) {
    final l = _listing;
    final hostName = ref.watch(hostNamesProvider)[widget.hostId] ?? '';
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            RouteHeader(
              title: 'Elegir carpeta',
              subtitle: hostName.isEmpty ? null : hostName,
              close: true,
            ),
            if (l != null) ...[
              _breadcrumb(l.path),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 0,
                  children: [
                    FilterPill(
                      label: 'Inicio (~)',
                      selected: l.path == l.home,
                      onTap: () => _load(''),
                    ),
                    FilterPill(
                      label: 'Subir',
                      selected: false,
                      onTap: () {
                        if (l.path != '/') _load(_parent(l.path));
                      },
                    ),
                    FilterPill(
                      label: 'Mostrar ocultas',
                      selected: _hidden,
                      onTap: _toggleHidden,
                    ),
                  ],
                ),
              ),
            ],
            Expanded(child: _body(l)),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (l != null)
                    Text(
                      l.path,
                      style: AppFonts.mono(size: 12, color: AppColors.muted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 8),
                  AppButton(
                    label: 'Usar esta carpeta',
                    height: 52,
                    radius: 14,
                    fontSize: 15,
                    bold: true,
                    expand: true,
                    onPressed: l == null
                        ? null
                        : () => Navigator.of(context).pop(l.path),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _breadcrumb(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    var acc = '';
    final items = <Widget>[_crumb('/', '/', root: true)];
    for (final p in parts) {
      acc = '$acc/$p';
      items.add(Icon(Icons.chevron_right, size: 16, color: AppColors.faint));
      items.add(_crumb(p, acc));
    }
    return SizedBox(
      height: 44,
      child: ListView(
        controller: _crumbs,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: items,
      ),
    );
  }

  Widget _crumb(String label, String target, {bool root = false}) => Semantics(
    container: true,
    button: true,
    label: root ? 'Carpeta raíz' : 'Ir a $label',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: () => _load(target),
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minWidth: 36),
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          label,
          style: AppFonts.mono(
            size: 13,
            weight: FontWeight.w600,
            color: AppColors.accentLight,
          ),
        ),
      ),
    ),
  );

  Widget _body(DirListing? l) {
    if (l == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error ?? 'No se pudo leer la carpeta',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.muted),
              ),
              const SizedBox(height: 12),
              AppButton(
                label: 'Ir a Inicio',
                onPressed: () => _load(''),
                style: AppButtonStyle.outline,
              ),
            ],
          ),
        ),
      );
    }
    if (l.entries.isEmpty) {
      return Center(
        child: Text(
          'Sin subcarpetas',
          style: AppText.body.copyWith(color: AppColors.muted),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      children: [
        for (final e in l.entries)
          Semantics(
            container: true,
            button: e.enterable,
            enabled: e.enterable,
            label: e.enterable
                ? 'Carpeta ${e.name}'
                : 'Carpeta ${e.name}, sin permiso',
            excludeSemantics: true,
            child: InkWell(
              onTap: e.enterable ? () => _load(_join(l.path, e.name)) : null,
              child: SizedBox(
                height: 48,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(
                        e.enterable
                            ? Icons.folder_outlined
                            : Icons.folder_off_outlined,
                        size: 20,
                        color: e.enterable
                            ? AppColors.secondary
                            : AppColors.faint,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          e.name,
                          style: AppFonts.inter(
                            size: 15,
                            color: e.enterable
                                ? AppColors.text
                                : AppColors.faint,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!e.enterable)
                        Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: AppColors.faint,
                        )
                      else
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: AppColors.faint,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (l.truncated)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Solo se muestran las primeras $listDirShown carpetas.',
              style: AppText.caption,
            ),
          ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
      ],
    );
  }
}

/// Folders a listing holds at most (see data/list_dir.dart).
const listDirShown = 2000;
