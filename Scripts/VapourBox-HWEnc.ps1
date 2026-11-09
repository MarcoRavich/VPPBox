import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

void main() => runApp(const HwEncApp());

const _background = Color(0xFF17191E);
const _panel = Color(0xFF202329);
const _line = Color(0xFF343842);
const _accent = Color(0xFF8978E8);

class HwEncApp extends StatelessWidget {
  const HwEncApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'VPPBox',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _background,
          colorScheme: ColorScheme.fromSeed(seedColor: _accent, brightness: Brightness.dark, surface: _panel),
          useMaterial3: true,
          dividerColor: _line,
          sliderTheme: SliderThemeData(activeTrackColor: _accent, thumbColor: Colors.white, overlayColor: _accent.withValues(alpha: .18)),
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
  final _encoder = TextEditingController(text: 'NVEncC64.exe');
  final _logScroll = ScrollController();
  final _queue = <String>[];
  final _log = <String>['Ready. Add videos or drop them into the queue.'];
  String? _sourceStill, _processedStill, _selected;
  String _codec = 'HEVC';
  double _split = .5, _cqp = 20, _knnStrength = .08, _knnRadius = 3, _debandRange = 15, _debandThreshold = 15, _debandDither = 15, _unsharpWeight = .5;
  int _width = 1920, _height = 1080;
  bool _knn = true, _deband = false, _unsharp = false, _resize = false, _audioCopy = true, _busy = false, _cancel = false;
  int _done = 0;
  Process? _process;

  @override
  void dispose() { _process?.kill(); _input.dispose(); _output.dispose(); _encoder.dispose(); _logScroll.dispose(); super.dispose(); }

  Future<List<String>> _pickVideos() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: true);
    return result?.files.map((f) => f.path).whereType<String>().toList() ?? [];
  }
  Future<void> _addVideos() async => _addPaths(await _pickVideos());
  void _addPaths(Iterable<String> paths) {
    setState(() {
      for (final p in paths) { if (File(p).existsSync() && !_queue.contains(p)) _queue.add(p); }
      _selected ??= _queue.isEmpty ? null : _queue.first;
      if (_selected != null) _input.text = _selected!;
      if (_output.text.isEmpty && _selected != null) _suggestOutput(_selected!);
    });
  }
  String _base(String path) => path.split(RegExp(r'[/\\]')).last;
  void _suggestOutput(String source) => _output.text = '${File(source).parent.path}${Platform.pathSeparator}${_base(source).replaceFirst(RegExp(r'\.[^.]+$'), '')}_encoded.mp4';
  Future<void> _chooseOutput() async {
    final path = await FilePicker.platform.saveFile(dialogTitle: 'Save encoded video', fileName: _output.text.isEmpty ? 'output.mp4' : _base(_output.text), type: FileType.video);
    if (path != null) setState(() => _output.text = path);
  }
  Future<void> _loadStill(bool source) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['png','jpg','jpeg','bmp','webp']);
    final p = r?.files.single.path;
    if (p != null) setState(() { if (source) { _sourceStill = p; } else { _processedStill = p; } });
  }
  List<String> _args(String input, String output) {
    final a = <String>['--avhw','--codec',_codec.toLowerCase(),'--cqp',_cqp.round().toString()];
    if (_knn) a.addAll(['--vpp-knn','radius=${_knnRadius.round()},strength=${_knnStrength.toStringAsFixed(2)}']);
    if (_deband) a.addAll(['--vpp-deband','range=${_debandRange.round()},thre=${_debandThreshold.round()},dither=${_debandDither.round()}']);
    if (_unsharp) a.addAll(['--vpp-unsharp','weight=${_unsharpWeight.toStringAsFixed(2)}']);
    if (_resize && _width > 0 && _height > 0) a.addAll(['--output-res','${_width}x$_height']);
    if (_audioCopy) a.add('--audio-copy');
    a.addAll(['-i',input,'-o',output]);
    return a;
  }
  String _quote(String s) => s.contains(RegExp(r'\s')) ? '"${s.replaceAll('"', r'\"')}"' : s;
  String get _command => '${_quote(_encoder.text.trim())} ${_args(_selected ?? 'INPUT', _output.text.isEmpty ? 'OUTPUT' : _output.text).map(_quote).join(' ')}';
  void _append(String text) {
    if (!mounted || text.trim().isEmpty) return;
    setState(() { _log.addAll(text.split(RegExp(r'\r?\n')).where((s) => s.isNotEmpty)); if (_log.length > 500) _log.removeRange(0, _log.length - 500); });
    WidgetsBinding.instance.addPostFrameCallback((_) { if (_logScroll.hasClients) _logScroll.jumpTo(_logScroll.position.maxScrollExtent); });
  }
  Future<void> _start() async {
    if (_queue.isEmpty) { _append('Add at least one source video.'); return; }
    if (_output.text.trim().isEmpty) { _append('Choose an output path.'); return; }
    setState(() { _busy = true; _cancel = false; _done = 0; _log.clear(); });
    for (final source in List<String>.from(_queue)) {
      if (_cancel) break;
      final out = _queue.length == 1 ? _output.text.trim() : _multiOutput(source);
      setState(() { _selected = source; _input.text = source; });
      final args = _args(source, out);
      _append('Encoding ${_base(source)}');
      _append('${_encoder.text.trim()} ${args.map(_quote).join(' ')}');
      try {
        _process = await Process.start(_encoder.text.trim().replaceAll('"',''), args, runInShell: false);
        _process!.stdout.transform(const SystemEncoding().decoder).listen(_append);
        _process!.stderr.transform(const SystemEncoding().decoder).listen(_append);
        final code = await _process!.exitCode;
        if (code == 0) { _done++; _append('Finished: $out'); } else { _append('NVEncC exited with code $code.'); }
      } catch (e) { _append('Could not launch NVEncC: $e'); break; }
    }
    if (mounted) { setState(() { _busy = false; _process = null; }); _append(_cancel ? 'Queue stopped.' : 'Queue complete: $_done/${_queue.length}.'); }
  }
  String _multiOutput(String source) {
    final ext = _output.text.contains('.') ? _output.text.substring(_output.text.lastIndexOf('.')) : '.mp4';
    return '${File(_output.text).parent.path}${Platform.pathSeparator}${_base(source).replaceFirst(RegExp(r'\.[^.]+$'), '')}_encoded$ext';
  }
  Future<void> _preset() async {
    final value = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const ListTile(title: Text('Quick presets'), subtitle: Text('Starting points for NVEncC VPP filters')),
      ListTile(title: const Text('Clean & preserve detail'), onTap: () => Navigator.pop(context,'clean')),
      ListTile(title: const Text('Restore gradients'), onTap: () => Navigator.pop(context,'deband')),
      ListTile(title: const Text('Resize to 1080p'), onTap: () => Navigator.pop(context,'resize')),
    ])));
    if (value == null) return;
    setState(() { _knn = value != 'resize'; _deband = value == 'deband'; _unsharp = value == 'clean'; _resize = value == 'resize'; _width = 1920; _height = 1080; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Column(children: [
    _toolbar(),
    Expanded(child: LayoutBuilder(builder: (context,c) => c.maxWidth < 860
      ? Column(children: [Expanded(child: _workspace()), SizedBox(height: 320, child: _settings())])
      : Row(children: [Expanded(flex: 7, child: _workspace()), SizedBox(width: 360, child: _settings())]))),
    _status(),
  ])));
  Widget _toolbar() => Container(height: 56, padding: const EdgeInsets.symmetric(horizontal: 16), decoration: const BoxDecoration(color: _panel,border: Border(bottom: BorderSide(color: _line))), child: Row(children: [const Icon(Icons.movie_filter_outlined,color:_accent),const SizedBox(width:9),const Text('VPPBox',style:TextStyle(fontSize:17,fontWeight:FontWeight.bold)),const Text('  /  NVEnc',style:TextStyle(color:Colors.white54)),const Spacer(),Text('${_queue.length} queued',style:const TextStyle(fontSize:11,color:Colors.white60)),IconButton(tooltip:'Presets',onPressed:_preset,icon:const Icon(Icons.tune)),IconButton(tooltip:'Add videos',onPressed:_addVideos,icon:const Icon(Icons.video_library_outlined)),IconButton(tooltip:'Output',onPressed:_chooseOutput,icon:const Icon(Icons.save_outlined))]));
  Widget _workspace() => Padding(padding:const EdgeInsets.all(14),child:Column(children:[Expanded(flex:7,child:_card(Column(children:[Row(children:[const Text('BEFORE / AFTER PREVIEW',style:TextStyle(fontSize:10,fontWeight:FontWeight.bold,color:Colors.white70,letterSpacing:1)),const Spacer(),_button('Original',Icons.image_outlined,()=>_loadStill(true)),const SizedBox(width:5),_button('Processed',Icons.image,()=>_loadStill(false))]),const SizedBox(height:8),Expanded(child:_Compare(source:_sourceStill,processed:_processedStill,split:_split,onChange:(v)=>setState(()=>_split=v))),Row(children:[const Text('Original',style:TextStyle(fontSize:10,color:Colors.white54)),Expanded(child:Slider(value:_split,min:.02,max:.98,onChanged:(v)=>setState(()=>_split=v))),const Text('Processed',style:TextStyle(fontSize:10,color:Colors.white54))])]))),const SizedBox(height:9),Expanded(flex:3,child:_queuePanel()),const SizedBox(height:9),SizedBox(height:112,child:_card(Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[const Text('PROCESSING LOG',style:TextStyle(fontSize:10,fontWeight:FontWeight.bold,color:Colors.white60)),const SizedBox(height:5),Expanded(child:ListView(controller:_logScroll,children:_log.map((s)=>Text(s,style:const TextStyle(fontFamily:'monospace',fontSize:10,color:Colors.white60))).toList()))]))) ]));
  Widget _queuePanel() => _card(Column(children:[Row(children:[const Text('VIDEO QUEUE',style:TextStyle(fontSize:10,fontWeight:FontWeight.bold,color:Colors.white70,letterSpacing:1)),const Spacer(),TextButton.icon(onPressed:_addVideos,icon:const Icon(Icons.add,size:15),label:const Text('Add')),TextButton(onPressed:_busy?null:()=>setState(()=>_queue.clear()),child:const Text('Clear'))]),Expanded(child:_queue.isEmpty?const Center(child:Text('Drop videos here or choose Add',style:TextStyle(color:Colors.white54))):ListView.builder(itemCount:_queue.length,itemBuilder:(context,i){final p=_queue[i];return ListTile(dense:true,selected:p==_selected,leading:Icon(p==_selected?Icons.play_arrow:Icons.video_file_outlined,color:p==_selected?_accent:Colors.white54),title:Text(_base(p),overflow:TextOverflow.ellipsis),subtitle:Text(p,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:9)),onTap:(){setState(()=>_selected=p);_input.text=p;_suggestOutput(p);},trailing:IconButton(icon:const Icon(Icons.close,size:16),onPressed:_busy?null:()=>setState(()=>_queue.remove(p))));} ))]));
  Widget _settings() => Container(decoration:const BoxDecoration(color:_panel,border:Border(left:BorderSide(color:_line))),child:Column(children:[const Padding(padding:EdgeInsets.all(13),child:Row(children:[Icon(Icons.tune,color:_accent,size:18),SizedBox(width:8),Text('ENCODE & VPP',style:TextStyle(fontSize:11,fontWeight:FontWeight.bold,letterSpacing:1))])),Expanded(child:ListView(padding:const EdgeInsets.fromLTRB(13,0,13,13),children:[_section('SOURCE & OUTPUT'),_path('Input',_input,_addVideos),const SizedBox(height:6),_path('Output',_output,_chooseOutput),const SizedBox(height:7),_smallLabel('NVEncC executable'),TextField(controller:_encoder,decoration:const InputDecoration(hintText:'NVEncC64.exe')),const SizedBox(height:9),_smallLabel('Codec'),DropdownButtonFormField<String>(value:_codec,items:const[DropdownMenuItem(value:'H.264',child:Text('H.264 / AVC')),DropdownMenuItem(value:'HEVC',child:Text('HEVC / H.265'))],onChanged:(v)=>setState(()=>_codec=v??'HEVC')),_section('ENCODING QUALITY'),_range('CQP quality',_cqp,1,51,(v)=>setState(()=>_cqp=v),value:_cqp.round().toString()),SwitchListTile.adaptive(contentPadding:EdgeInsets.zero,dense:true,title:const Text('Copy audio',style:TextStyle(fontSize:11)),value:_audioCopy,onChanged:(v)=>setState(()=>_audioCopy=v)),_section('VPP FILTER PIPELINE'),_filter('DENOISE','--vpp-knn',_knn,(v)=>setState(()=>_knn=v),[_range('Strength',_knnStrength,0,1,(v)=>setState(()=>_knnStrength=v),value:_knnStrength.toStringAsFixed(2)),_range('Radius',_knnRadius,1,5,(v)=>setState(()=>_knnRadius=v),divisions:4,value:_knnRadius.round().toString())]),_filter('DEBAND','--vpp-deband',_deband,(v)=>setState(()=>_deband=v),[_range('Range',_debandRange,0,127,(v)=>setState(()=>_debandRange=v),divisions:127,value:_debandRange.round().toString()),_range('Threshold',_debandThreshold,0,31,(v)=>setState(()=>_debandThreshold=v),divisions:31,value:_debandThreshold.round().toString()),_range('Dither',_debandDither,0,31,(v)=>setState(()=>_debandDither=v),divisions:31,value:_debandDither.round().toString())]),_filter('DETAIL','--vpp-unsharp',_unsharp,(v)=>setState(()=>_unsharp=v),[_range('Weight',_unsharpWeight,0,10,(v)=>setState(()=>_unsharpWeight=v),value:_unsharpWeight.toStringAsFixed(2))]),_filter('FRAMING','--output-res',_resize,(v)=>setState(()=>_resize=v),[Row(children:[Expanded(child:_number('Width',_width,(v)=>setState(()=>_width=v))),const SizedBox(width:7),Expanded(child:_number('Height',_height,(v)=>setState(()=>_height=v)))])]),_section('COMMAND PREVIEW'),Container(color:_background,padding:const EdgeInsets.all(8),child:SelectableText(_command,style:const TextStyle(fontFamily:'monospace',fontSize:9,color:Colors.white70))) ]))]));
  Widget _status() => Container(height:46,padding:const EdgeInsets.symmetric(horizontal:16),decoration:const BoxDecoration(color:_panel,border:Border(top:BorderSide(color:_line))),child:Row(children:[Icon(Icons.circle,size:8,color:_busy?Colors.orangeAccent:Colors.greenAccent),const SizedBox(width:7),Text(_busy?'Encoding ${_done+1}/${_queue.length}':'Ready',style:const TextStyle(fontSize:11,color:Colors.white70)),const Spacer(),if(_busy)TextButton.icon(onPressed:(){_cancel=true;_process?.kill();},icon:const Icon(Icons.stop,size:16),label:const Text('Stop')),const SizedBox(width:6),FilledButton.icon(onPressed:_busy?null:_start,icon:Icon(_busy?Icons.hourglass_top:Icons.play_arrow,size:17),label:Text(_busy?'Encoding…':'Go (${_queue.length})'),style:FilledButton.styleFrom(backgroundColor:_accent))]));
  Widget _card(Widget child)=>Container(width:double.infinity,padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:_panel,border:Border.all(color:_line),borderRadius:BorderRadius.circular(6)),child:child);
  Widget _section(String text)=>Padding(padding:const EdgeInsets.only(top:10,bottom:6),child:Text(text,style:const TextStyle(fontSize:9,fontWeight:FontWeight.bold,color:Colors.white54,letterSpacing:1)));
  Widget _smallLabel(String text)=>Padding(padding:const EdgeInsets.only(bottom:4),child:Text(text,style:const TextStyle(fontSize:10,color:Colors.white60)));
  Widget _path(String label,TextEditingController c,VoidCallback pick)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[_smallLabel(label),Row(children:[Expanded(child:TextField(controller:c,decoration:InputDecoration(hintText:'Choose $label…'))),IconButton(onPressed:pick,icon:const Icon(Icons.folder_open,size:17))])]);
  Widget _button(String s,IconData i,VoidCallback f)=>OutlinedButton.icon(onPressed:f,icon:Icon(i,size:14),label:Text(s,style:const TextStyle(fontSize:10)),style:OutlinedButton.styleFrom(padding:const EdgeInsets.symmetric(horizontal:8,vertical:5)));
  Widget _range(String label,double v,double min,double max,ValueChanged<double> change,{int? divisions,required String value})=>Row(children:[SizedBox(width:67,child:Text(label,style:const TextStyle(fontSize:9,color:Colors.white60))),Expanded(child:Slider(value:v.clamp(min,max),min:min,max:max,divisions:divisions,onChanged:change)),SizedBox(width:30,child:Text(value,textAlign:TextAlign.right,style:const TextStyle(fontSize:9,fontFeatures:[FontFeature.tabularFigures()] )))]);
  Widget _filter(String title,String flag,bool value,ValueChanged<bool> changed,List<Widget> children)=>Container(margin:const EdgeInsets.only(bottom:6),decoration:BoxDecoration(color:const Color(0xFF292D35),borderRadius:BorderRadius.circular(5)),child:ExpansionTile(initiallyExpanded:value,tilePadding:const EdgeInsets.symmetric(horizontal:7),childrenPadding:const EdgeInsets.fromLTRB(8,0,8,7),leading:Checkbox(value:value,onChanged:(v)=>changed(v??false)),title:Text(title,style:const TextStyle(fontSize:10,fontWeight:FontWeight.bold)),subtitle:Text(flag,style:const TextStyle(fontFamily:'monospace',fontSize:8,color:Colors.white54)),children:children));
  Widget _number(String label,int val,ValueChanged<int> update)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[_smallLabel(label),TextFormField(initialValue:val.toString(),keyboardType:TextInputType.number,onChanged:(s)=>update(int.tryParse(s)??0),decoration:const InputDecoration())]);
}

class _Compare extends StatelessWidget {
  const _Compare({required this.source,required this.processed,required this.split,required this.onChange});
  final String? source,processed; final double split; final ValueChanged<double> onChange;
  @override Widget build(BuildContext context)=>LayoutBuilder(builder:(context,c){final w=c.maxWidth;return GestureDetector(behavior:HitTestBehavior.opaque,onTapDown:(d)=>onChange((d.localPosition.dx/w).clamp(.02,.98)),onHorizontalDragUpdate:(d)=>onChange((split+d.delta.dx/w).clamp(.02,.98)),child:ClipRRect(borderRadius:BorderRadius.circular(4),child:Stack(fit:StackFit.expand,children:[_picture(processed,const Color(0xFF303841)),ClipRect(clipper:_Clip(split),child:_picture(source,const Color(0xFF414149))),Positioned(left:w*split-1.5,top:0,bottom:0,child:Container(width:3,color:Colors.white,boxShadow:[BoxShadow(color:Colors.black.withValues(alpha:.5),blurRadius:4)])),Positioned(left:w*split-18,top:c.maxHeight/2-18,child:Container(width:36,height:36,decoration:const BoxDecoration(color:Colors.white,shape:BoxShape.circle),child:const Icon(Icons.compare_arrows,color:Colors.black87,size:18))),Positioned(left:9,top:9,child:_label('Original')),Positioned(right:9,top:9,child:_label('Processed')),if(source==null&&processed==null)const Center(child:Text('Load stills to compare',style:TextStyle(color:Colors.white60)))])));});
  Widget _picture(String? path,Color fallback)=>ColoredBox(color:fallback,child:path==null?const SizedBox.expand():Image.file(File(path),fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Center(child:Text('Image unavailable'))));
  Widget _label(String text)=>Container(padding:const EdgeInsets.symmetric(horizontal:7,vertical:4),decoration:BoxDecoration(color:Colors.black.withValues(alpha:.7),borderRadius:BorderRadius.circular(4)),child:Text(text,style:const TextStyle(fontSize:9)));
}
class _Clip extends CustomClipper<Rect>{const _Clip(this.split);final double split;@override Rect getClip(Size s)=>Rect.fromLTWH(0,0,s.width*split,s.height);@override bool shouldReclip(_Clip old)=>old.split!=split;}
