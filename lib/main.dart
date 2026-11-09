import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

void main() => runApp(const HwEncApp());

const _bg = Color(0xFF111318);
const _panel = Color(0xFF1A1D24);
const _panel2 = Color(0xFF222630);
const _accent = Color(0xFF8A78F0);

class HwEncApp extends StatelessWidget {
  const HwEncApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VapourBox HWEnc',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: _accent,
            brightness: Brightness.dark,
            surface: _panel,
          ),
          useMaterial3: true,
          sliderTheme: SliderThemeData(
            activeTrackColor: _accent,
            thumbColor: Colors.white,
            overlayColor: _accent.withValues(alpha: .18),
          ),
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: _bg,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: .09)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.white.withValues(alpha: .09)),
            ),
          ),
        ),
        home: const EncoderWorkspace(),
      );
}

class EncoderWorkspace extends StatefulWidget {
  const EncoderWorkspace({super.key});
  @override
  State<EncoderWorkspace> createState() => _EncoderWorkspaceState();
}

class _EncoderWorkspaceState extends State<EncoderWorkspace> {
  final _input = TextEditingController();
  final _output = TextEditingController();
  final _encoder = TextEditingController(text: 'NVEncC.exe');
  final _log = ScrollController();
  String? _originalStill;
  String? _processedStill;
  String _codec = 'H.264';
  double _split = .5;
  double _knnStrength = .08;
  double _knnRadius = 3;
  double _debandRange = 15;
  double _debandThreshold = 15;
  double _unsharpWeight = .5;
  double _resizeWidth = 0;
  double _resizeHeight = 0;
  bool _knn = true;
  bool _deband = false;
  bool _unsharp = false;
  bool _resize = false;
  bool _encoding = false;
  String _status = 'Ready';
  final List<String> _messages = ['Choose a video to get started.'];
  Process? _process;

  @override
  void dispose() {
    _process?.kill();
    _input.dispose();
    _output.dispose();
    _encoder.dispose();
    _log.dispose();
    super.dispose();
  }

  Future<String?> _pickFile({List<String>? extensions}) async {
    final result = await FilePicker.platform.pickFiles(
      type: extensions == null ? FileType.video : FileType.custom,
      allowedExtensions: extensions,
    );
    return result?.files.single.path;
  }

  Future<void> _selectInput() async {
    final path = await _pickFile();
    if (path == null) return;
    setState(() {
      _input.text = path;
      if (_output.text.isEmpty) {
        final file = File(path);
        _output.text = '${file.parent.path}${Platform.pathSeparator}'
            '${file.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '')}_encoded.mp4';
      }
    });
  }

  Future<void> _selectStill(bool original) async {
    final path = await _pickFile(extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp']);
    if (path != null) setState(() => original ? _originalStill = path : _processedStill = path);
  }

  Future<void> _selectOutput() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save encoded video',
      fileName: _output.text.isEmpty ? 'output.mp4' : _output.text.split(Platform.pathSeparator).last,
      type: FileType.video,
    );
    if (path != null) setState(() => _output.text = path);
  }

  List<String> _arguments() {
    final args = <String>['--avhw', '--codec', _codec == 'H.264' ? 'h264' : 'hevc',
      '-i', _input.text.trim(), '-o', _output.text.trim()];
    if (_knn) args.addAll(['--vpp-knn', 'radius=${_knnRadius.round()},strength=${_knnStrength.toStringAsFixed(3)}']);
    if (_deband) args.addAll(['--vpp-deband', 'range=${_debandRange.round()},thre=${_debandThreshold.round()}']);
    if (_unsharp) args.addAll(['--vpp-unsharp', 'weight=${_unsharpWeight.toStringAsFixed(2)}']);
    if (_resize && _resizeWidth > 0 && _resizeHeight > 0) {
      args.addAll(['--output-res', '${_resizeWidth.round()}x${_resizeHeight.round()}']);
    }
    return args;
  }

  String get _commandPreview => '${_encoder.text.trim()} ${_arguments().map(_quote).join(' ')}';
  String _quote(String value) => value.contains(' ') ? '"$value"' : value;

  Future<void> _startEncode() async {
    if (_input.text.trim().isEmpty || _output.text.trim().isEmpty) {
      _append('Select an input video and output path first.');
      return;
    }
    setState(() { _encoding = true; _status = 'Encoding…'; });
    _append('Starting NVEncC…\n$_commandPreview');
    try {
      final executable = _encoder.text.trim().replaceAll('"', '');
      _process = await Process.start(executable, _arguments(), runInShell: false);
      _process!.stdout.transform(const SystemEncoding().decoder).listen(_append);
      _process!.stderr.transform(const SystemEncoding().decoder).listen(_append);
      final code = await _process!.exitCode;
      if (!mounted) return;
      setState(() { _encoding = false; _status = code == 0 ? 'Completed' : 'Failed (exit $code)'; });
      _append(code == 0 ? 'Encode completed.' : 'NVEncC exited with code $code.');
    } catch (error) {
      if (!mounted) return;
      setState(() { _encoding = false; _status = 'Could not start NVEncC'; });
      _append('Could not launch encoder: $error');
    }
  }

  void _append(String message) {
    if (!mounted) return;
    setState(() => _messages.addAll(message.split('\n').where((line) => line.isNotEmpty)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_log.hasClients) _log.jumpTo(_log.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            _buildHeader(),
            Expanded(child: LayoutBuilder(builder: (context, constraints) {
              if (constraints.maxWidth < 850) {
                return Column(children: [
                  Expanded(child: _buildPreview()),
                  SizedBox(height: 340, child: _buildFilters()),
                ]);
              }
              return Row(children: [
                Expanded(flex: 7, child: Column(children: [
                  Expanded(child: _buildPreview()),
                  _buildTimelineFooter(),
                ])),
                SizedBox(width: 350, child: _buildFilters()),
              ]);
            })),
            _buildBottomBar(),
          ]),
        ),
      );

  Widget _buildHeader() => Container(
        height: 62,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(color: _panel, border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: .07)))),
        child: Row(children: [
          const Icon(Icons.movie_filter_outlined, color: _accent, size: 25),
          const SizedBox(width: 10),
          const Text('VapourBox', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const Text('  /  HWEnc', style: TextStyle(fontSize: 16, color: Colors.white54)),
          const SizedBox(width: 24),
          Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: _accent.withValues(alpha: .15), borderRadius: BorderRadius.circular(6)), child: const Text('NVENC', style: TextStyle(color: Color(0xFFB8ADFF), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1))),
          const Spacer(),
          IconButton(onPressed: _selectInput, tooltip: 'Open video', icon: const Icon(Icons.video_file_outlined)),
          IconButton(onPressed: _selectOutput, tooltip: 'Choose output', icon: const Icon(Icons.save_outlined)),
          const SizedBox(width: 8),
        ]),
      );

  Widget _buildPreview() => Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Text('COMPARATIVE PREVIEW', style: TextStyle(color: Colors.white60, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            const Spacer(),
            _stillButton('Load original still', Icons.add_photo_alternate_outlined, () => _selectStill(true)),
            const SizedBox(width: 8),
            _stillButton('Load processed still', Icons.image_outlined, () => _selectStill(false)),
          ]),
          const SizedBox(height: 10),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(10), child: _ComparisonPreview(
            original: _originalStill, processed: _processedStill, split: _split,
            onSplitChanged: (value) => setState(() => _split = value),
          ))),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Original', style: TextStyle(color: Colors.white54, fontSize: 11)),
            Expanded(child: Slider(value: _split, min: .02, max: .98, onChanged: (v) => setState(() => _split = v))),
            const Text('Processed', style: TextStyle(color: Colors.white54, fontSize: 11)),
          ]),
        ]),
      );

  Widget _stillButton(String label, IconData icon, VoidCallback onPressed) => OutlinedButton.icon(
        onPressed: onPressed, icon: Icon(icon, size: 16), label: Text(label, style: const TextStyle(fontSize: 11)),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), foregroundColor: Colors.white70, side: BorderSide(color: Colors.white.withValues(alpha: .12))),
      );

  Widget _buildTimelineFooter() => Container(
        height: 82, margin: const EdgeInsets.fromLTRB(18, 0, 18, 14), padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(9)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [const Icon(Icons.linear_scale, size: 15, color: _accent), const SizedBox(width: 7), Text(_input.text.isEmpty ? 'No source loaded' : _input.text.split(Platform.pathSeparator).last, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)), const Spacer(), Text(_status, style: const TextStyle(fontSize: 11, color: Colors.white54))]),
          const SizedBox(height: 8),
          Expanded(child: GestureDetector(onTapDown: (d) => setState(() => _split = (d.localPosition.dx / MediaQuery.sizeOf(context).width).clamp(.02, .98)), child: Container(decoration: BoxDecoration(color: _panel2, borderRadius: BorderRadius.circular(4)), child: Align(alignment: Alignment(_split * 2 - 1, 0), child: Container(width: 2, color: _accent))))),
        ]),
      );

  Widget _buildFilters() => Container(
        decoration: BoxDecoration(color: _panel, border: Border(left: BorderSide(color: Colors.white.withValues(alpha: .07)))),
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 12), child: Row(children: [const Icon(Icons.tune, size: 18, color: _accent), const SizedBox(width: 9), const Text('ENCODE & VPP', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)), const Spacer(), IconButton(tooltip: 'Reload settings', onPressed: () => setState(() {}), icon: const Icon(Icons.more_horiz))])),
          Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            _sectionTitle('SOURCE & OUTPUT'),
            _pathRow('Input video', _input, _selectInput, Icons.video_file_outlined),
            const SizedBox(height: 8),
            _pathRow('Output file', _output, _selectOutput, Icons.save_outlined),
            const SizedBox(height: 8),
            _fieldLabel('NVEncC executable'),
            TextField(controller: _encoder, decoration: const InputDecoration(hintText: r'C:\NVEnc\NVEncC.exe')),
            const SizedBox(height: 14),
            _fieldLabel('Video codec'),
            DropdownButtonFormField<String>(value: _codec, items: const [DropdownMenuItem(value: 'H.264', child: Text('H.264 / AVC')), DropdownMenuItem(value: 'HEVC', child: Text('HEVC / H.265'))], onChanged: (v) => setState(() => _codec = v ?? 'H.264')),
            const SizedBox(height: 20),
            _sectionTitle('VIDEO PROCESSING FILTERS'),
            _filterCard(title: 'KNN Denoise', option: '--vpp-knn', enabled: _knn, onEnabled: (v) => setState(() => _knn = v), children: [
              _valueSlider('Strength', _knnStrength, 0, 1, (v) => setState(() => _knnStrength = v), precision: 2),
              _valueSlider('Radius', _knnRadius, 1, 5, (v) => setState(() => _knnRadius = v), divisions: 4, suffix: ''),
            ]),
            _filterCard(title: 'Deband', option: '--vpp-deband', enabled: _deband, onEnabled: (v) => setState(() => _deband = v), children: [
              _valueSlider('Range', _debandRange, 0, 127, (v) => setState(() => _debandRange = v), divisions: 127, suffix: ''),
              _valueSlider('Threshold', _debandThreshold, 0, 31, (v) => setState(() => _debandThreshold = v), divisions: 31, suffix: ''),
            ]),
            _filterCard(title: 'Unsharp', option: '--vpp-unsharp', enabled: _unsharp, onEnabled: (v) => setState(() => _unsharp = v), children: [
              _valueSlider('Weight', _unsharpWeight, 0, 10, (v) => setState(() => _unsharpWeight = v), precision: 1),
            ]),
            _filterCard(title: 'Resize', option: '--output-res', enabled: _resize, onEnabled: (v) => setState(() => _resize = v), children: [
              Row(children: [Expanded(child: _numberField('Width', _resizeWidth, (v) => setState(() => _resizeWidth = v))), const SizedBox(width: 8), Expanded(child: _numberField('Height', _resizeHeight, (v) => setState(() => _resizeHeight = v)))]),
            ]),
            const SizedBox(height: 12),
            _sectionTitle('GENERATED COMMAND'),
            Container(padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(8)), child: SelectableText(_commandPreview, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white60, height: 1.5))),
            const SizedBox(height: 12),
            _sectionTitle('ENCODER LOG'),
            Container(height: 110, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(8)), child: ListView(controller: _log, children: _messages.map((m) => Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(m, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white60)))).toList())),
          ])),
        ]),
      );

  Widget _sectionTitle(String title) => Padding(padding: const EdgeInsets.only(bottom: 9), child: Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1, color: Colors.white54)));
  Widget _fieldLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: const TextStyle(fontSize: 11, color: Colors.white60)));
  Widget _pathRow(String label, TextEditingController controller, VoidCallback browse, IconData icon) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_fieldLabel(label), Row(children: [Expanded(child: TextField(controller: controller, decoration: InputDecoration(hintText: label == 'Input video' ? 'Choose a video…' : 'Choose output…'))), const SizedBox(width: 6), IconButton.filledTonal(onPressed: browse, tooltip: 'Browse', icon: Icon(icon, size: 18))])]);
  Widget _numberField(String label, double value, ValueChanged<double> onChanged) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_fieldLabel(label), TextFormField(initialValue: value == 0 ? '' : value.round().toString(), keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'e.g. 1920'), onChanged: (v) => onChanged(double.tryParse(v) ?? 0))]);

  Widget _filterCard({required String title, required String option, required bool enabled, required ValueChanged<bool> onEnabled, required List<Widget> children}) => Container(
        margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.fromLTRB(11, 5, 11, 10),
        decoration: BoxDecoration(color: _panel2.withValues(alpha: .65), borderRadius: BorderRadius.circular(9), border: Border.all(color: Colors.white.withValues(alpha: .05))),
        child: Column(children: [Row(children: [Switch.adaptive(value: enabled, onChanged: onEnabled, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap), const SizedBox(width: 6), Expanded(child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))), Text(option, style: const TextStyle(fontSize: 9, color: Colors.white38, fontFamily: 'monospace'))]), if (enabled) ...children]),
      );

  Widget _valueSlider(String label, double value, double min, double max, ValueChanged<double> onChanged, {int? divisions, int precision = 0, String suffix = ''}) => Padding(padding: const EdgeInsets.only(top: 5), child: Row(children: [SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60))), Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: onChanged)), SizedBox(width: 38, child: Text('${value.toStringAsFixed(precision)}$suffix', textAlign: TextAlign.right, style: const TextStyle(fontSize: 10, color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()]))) ]));

  Widget _buildBottomBar() => Container(
        height: 58, padding: const EdgeInsets.symmetric(horizontal: 18), decoration: BoxDecoration(color: _panel, border: Border(top: BorderSide(color: Colors.white.withValues(alpha: .07)))),
        child: Row(children: [Icon(_encoding ? Icons.autorenew : Icons.circle, size: 9, color: _encoding ? Colors.orangeAccent : Colors.greenAccent), const SizedBox(width: 8), Text(_status, style: const TextStyle(fontSize: 11, color: Colors.white60)), const Spacer(), if (_encoding) TextButton.icon(onPressed: () { _process?.kill(); setState(() { _encoding = false; _status = 'Cancelled'; }); }, icon: const Icon(Icons.stop, size: 17), label: const Text('Cancel')), const SizedBox(width: 8), FilledButton.icon(onPressed: _encoding ? null : _startEncode, icon: Icon(_encoding ? Icons.hourglass_top : Icons.play_arrow, size: 18), label: Text(_encoding ? 'Encoding…' : 'Start encode'), style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12))) ]),
      );
}

class _ComparisonPreview extends StatelessWidget {
  const _ComparisonPreview({required this.original, required this.processed, required this.split, required this.onSplitChanged});
  final String? original;
  final String? processed;
  final double split;
  final ValueChanged<double> onSplitChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final width = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onSplitChanged((d.localPosition.dx / width).clamp(.02, .98)),
          onHorizontalDragUpdate: (d) => onSplitChanged((split + d.delta.dx / width).clamp(.02, .98)),
          child: Stack(fit: StackFit.expand, children: [
            _previewImage(processed, const Color(0xFF283841), 'PROCESSED'),
            ClipRect(clipper: _LeftClipper(split), child: _previewImage(original, const Color(0xFF354047), 'ORIGINAL')),
            Positioned(left: width * split - 1.5, top: 0, bottom: 0, child: Container(width: 3, color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .45), blurRadius: 5)])),
            Positioned(left: width * split - 20, top: box.maxHeight / 2 - 20, child: Container(width: 40, height: 40, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .35), blurRadius: 6)]), child: const Icon(Icons.compare_arrows, color: Colors.black87, size: 21))),
            Positioned(left: 12, top: 12, child: _badge('Original')),
            Positioned(right: 12, top: 12, child: _badge('Processed')),
            if (original == null && processed == null) Center(child: Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .4), borderRadius: BorderRadius.circular(12)), child: const Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.compare, size: 35, color: Colors.white60), SizedBox(height: 10), Text('Sliding comparison preview', style: TextStyle(fontWeight: FontWeight.w600)), SizedBox(height: 5), Text('Load original and processed stills to compare', style: TextStyle(fontSize: 11, color: Colors.white60))]))),
          ]),
        );
      });

  Widget _previewImage(String? path, Color fallback, String label) => ColoredBox(color: fallback, child: path == null ? Center(child: Icon(Icons.image_outlined, size: 45, color: Colors.white.withValues(alpha: .18))) : Image.file(File(path), fit: BoxFit.contain, errorBuilder: (_, __, ___) => Center(child: Text('Could not load $label still', style: const TextStyle(color: Colors.white54)))));
  Widget _badge(String text) => Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .65), borderRadius: BorderRadius.circular(5)), child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)));
}

class _LeftClipper extends CustomClipper<Rect> {
  const _LeftClipper(this.split);
  final double split;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * split, size.height);
  @override
  bool shouldReclip(_LeftClipper oldClipper) => oldClipper.split != split;
}
