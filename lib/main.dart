import 'dart:async'; // Required for crash protection
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, SystemNavigator; // SystemNavigator for Android exit
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_painter/image_painter.dart';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

// 🔥 CRASH PROTECTION: Wrap main in a safety zone
void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppSettings.init();
    runApp(const ReportApp());
  }, (error, stack) {
    print("CRITICAL ERROR CAUGHT: $error");
  });
}

// --- 1. SETTINGS & SAFE BACKUP MANAGER ---
class AppSettings {
  static late SharedPreferences _prefs;
  static int _quality = 80;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _quality = _prefs.getInt('image_quality') ?? 80;
  }

  static int get quality => _quality;

  static Future<void> setQuality(int value) async {
    _quality = value;
    await _prefs.setInt('image_quality', value);
  }
}

class BackupManager {
  // 🔥 BACKGROUND BACKUP: Prevents "Watchdog" freeze crashes
  static Future<void> createBackup(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Small delay to let UI render before work starts
      await Future.delayed(const Duration(milliseconds: 100));

      final appDir = await getApplicationDocumentsDirectory();
      final zipPath = '${appDir.path}/cxpro_backup_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.zip';
      
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      
      final reportsFile = File('${appDir.path}/reports_db.json');
      final projectsFile = File('${appDir.path}/projects_db.json');
      
      if (await reportsFile.exists()) encoder.addFile(reportsFile);
      if (await projectsFile.exists()) encoder.addFile(projectsFile);

      final files = appDir.listSync();
      for (var file in files) {
        if (file is File && (file.path.endsWith('.jpg') || file.path.endsWith('.png'))) {
          encoder.addFile(file);
        }
      }
      encoder.close();

      if (context.mounted) Navigator.pop(context);

      // Fix for iPad/Share crash
      final box = context.findRenderObject() as RenderBox?;
      if (context.mounted) {
        await Share.shareXFiles(
          [XFile(zipPath)],
          text: 'Cx Pro Data Backup',
          sharePositionOrigin: box!.localToGlobal(Offset.zero) & box.size,
        );
      }

    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Backup Failed: $e")));
      }
    }
  }

  static Future<void> restoreBackup(BuildContext context) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (result != null) {
        final file = File(result.files.single.path!);
        final bytes = await file.readAsBytes();
        final archive = ZipDecoder().decodeBytes(bytes);
        final appDir = await getApplicationDocumentsDirectory();

        for (final archiveFile in archive) {
          if (archiveFile.isFile) {
            final data = archiveFile.content as List<int>;
            File('${appDir.path}/${archiveFile.name}')..createSync(recursive: true)..writeAsBytesSync(data);
          }
        }
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Restore Successful! Please restart app.")));
      }
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Restore Failed: $e")));
    }
  }
}

// --- 2. DATA MODELS ---
class ReportItem {
  String imagePath;
  String heading;
  String comment;
  DateTime date;

  ReportItem({required this.imagePath, this.heading = "", this.comment = "", DateTime? date}) 
      : date = date ?? DateTime.now();

  Map<String, dynamic> toJson() => {'imagePath': imagePath, 'heading': heading, 'comment': comment, 'date': date.toIso8601String()};
  factory ReportItem.fromJson(Map<String, dynamic> json) => ReportItem(
      imagePath: json['imagePath'], 
      heading: json['heading'] ?? "", 
      comment: json['comment'] ?? "", 
      date: json['date'] != null ? DateTime.parse(json['date']) : DateTime.now()
  );
}

class InspectionReport {
  String id;
  String projectId;
  String itemName;
  String location;
  String type;
  DateTime createdAt;
  List<ReportItem> items;

  InspectionReport({required this.id, required this.projectId, required this.itemName, required this.location, required this.type, required this.createdAt, required this.items});

  String get title => "$itemName - $location";

  Map<String, dynamic> toJson() => {'id': id, 'projectId': projectId, 'itemName': itemName, 'location': location, 'type': type, 'createdAt': createdAt.toIso8601String(), 'items': items.map((i) => i.toJson()).toList()};
  factory InspectionReport.fromJson(Map<String, dynamic> json) => InspectionReport(
      id: json['id'], 
      projectId: json['projectId'] ?? "default", 
      itemName: json['itemName'] ?? "Unknown Item", 
      location: json['location'] ?? "Unknown Location", 
      type: json['type'] ?? 'inspection', 
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt']) : DateTime.now(), 
      items: (json['items'] as List).map((i) => ReportItem.fromJson(i)).toList()
  );
}

class Project {
  String id;
  String name;
  DateTime lastModified;

  Project({required this.id, required this.name, required this.lastModified});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'lastModified': lastModified.toIso8601String()};
  factory Project.fromJson(Map<String, dynamic> json) => Project(
    id: json['id'], 
    name: json['name'], 
    lastModified: json['lastModified'] != null ? DateTime.parse(json['lastModified']) : DateTime.now()
  );
}

// --- 3. DATABASE (SELF-HEALING) ---
class ReportDatabase {
  static Future<String> _getDocPath() async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  // 🔥 SELF-HEALING LOAD: Automatically deletes corrupted files so app can open
  static Future<List<Project>> loadProjects() async {
    final path = await _getDocPath();
    final file = File('$path/projects_db.json');
    if (!await file.exists()) return [];
    try {
      final content = await file.readAsString();
      if (content.isEmpty) return []; // Handle empty file crash
      final List<dynamic> jsonList = jsonDecode(content);
      return jsonList.map((j) => Project.fromJson(j)).toList();
    } catch (e) { 
      print("Projects DB Corrupted. Resetting file. Error: $e");
      await file.delete(); 
      return []; 
    }
  }

  static Future<void> saveProjects(List<Project> projects) async {
    final path = await _getDocPath();
    await File('$path/projects_db.json').writeAsString(jsonEncode(projects.map((p) => p.toJson()).toList()));
  }

  static Future<List<InspectionReport>> loadReports(String projectId) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/reports_db.json');
    if (!await file.exists()) return [];
    try {
      final content = await file.readAsString();
      if (content.isEmpty) return [];
      final List<dynamic> rawList = jsonDecode(content);
      final List<InspectionReport> allReports = [];

      for (var item in rawList) {
        try {
          final report = InspectionReport.fromJson(item);
          for (var rItem in report.items) {
            final fileName = rItem.imagePath.split('/').last;
            rItem.imagePath = '${directory.path}/$fileName';
          }
          allReports.add(report);
        } catch (_) {}
      }
      return allReports.where((r) => r.projectId == projectId).toList();
    } catch (e) {
      print("Reports DB Corrupted. Resetting file. Error: $e");
      await file.delete(); 
      return []; 
    }
  }

  static Future<int> rescueOrphanReports(String targetProjectId) async {
    final path = await _getDocPath();
    final file = File('$path/reports_db.json');
    if (!await file.exists()) return 0;
    try {
      final content = await file.readAsString();
      final List<dynamic> rawList = jsonDecode(content);
      List<InspectionReport> allReports = [];
      int rescuedCount = 0;
      for (var item in rawList) {
        try {
          var report = InspectionReport.fromJson(item);
          if (report.projectId == "default" || report.projectId.isEmpty || report.projectId.length < 5) {
            report.projectId = targetProjectId;
            rescuedCount++;
          }
          allReports.add(report);
        } catch (_) {}
      }
      await file.writeAsString(jsonEncode(allReports.map((r) => r.toJson()).toList()));
      return rescuedCount;
    } catch (e) { return 0; }
  }

  static Future<void> deleteReport(String reportId) async {
    final path = await _getDocPath();
    final file = File('$path/reports_db.json');
    if (!await file.exists()) return;
    try {
      final content = await file.readAsString();
      List<InspectionReport> allReports = (jsonDecode(content) as List).map((j) => InspectionReport.fromJson(j)).toList();
      allReports.removeWhere((r) => r.id == reportId);
      await file.writeAsString(jsonEncode(allReports.map((r) => r.toJson()).toList()));
    } catch (e) {}
  }

  static Future<void> saveReport(InspectionReport report) async {
    final path = await _getDocPath();
    final file = File('$path/reports_db.json');
    List<InspectionReport> allReports = [];
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        allReports = (jsonDecode(content) as List).map((j) => InspectionReport.fromJson(j)).toList();
      } catch (e) { allReports = []; }
    }
    final index = allReports.indexWhere((r) => r.id == report.id);
    if (index != -1) { allReports[index] = report; } else { allReports.add(report); }
    await file.writeAsString(jsonEncode(allReports.map((r) => r.toJson()).toList()));
  }

  static Future<String> saveCompressedImage(XFile imageFile) async {
    final directory = await getApplicationDocumentsDirectory();
    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final targetPath = '${directory.path}/$fileName';
    var result = await FlutterImageCompress.compressAndGetFile(imageFile.path, targetPath, minWidth: 800, minHeight: 800, quality: AppSettings.quality, format: CompressFormat.jpeg);
    if (result == null) throw Exception("Compression failed");
    return result.path;
  }
  
  static Future<String> saveAnnotatedImage(Uint8List bytes) async {
    final directory = await getApplicationDocumentsDirectory();
    final fileName = 'annotated_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final targetPath = '${directory.path}/$fileName';
    await File(targetPath).writeAsBytes(await FlutterImageCompress.compressWithList(bytes, minHeight: 800, minWidth: 800, quality: AppSettings.quality, format: CompressFormat.jpeg));
    return targetPath;
  }
}

// --- 4. UI SCREENS ---
class ReportApp extends StatelessWidget {
  const ReportApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cx Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(backgroundColor: Colors.indigo, foregroundColor: Colors.white, centerTitle: true),
      ),
      home: const ProjectListScreen(),
    );
  }
}

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});
  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Colors.indigo),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(height: 80, width: 80, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white, border: Border.all(color: Colors.white, width: 2)),
                  child: ClipOval(child: Image.asset('assets/logo.png', fit: BoxFit.contain, errorBuilder: (context, error, stackTrace) => const Icon(Icons.business, size: 40, color: Colors.indigo)))),
                const SizedBox(height: 10),
                const Text("Cx Pro", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          ListTile(leading: const Icon(Icons.home), title: const Text('Projects'), onTap: () => Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (c) => const ProjectListScreen()), (r) => false)),
          ListTile(leading: const Icon(Icons.folder_special), title: const Text('Saved Outputs'), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (context) => const SavedReportsScreen())); }),
          ListTile(leading: const Icon(Icons.settings), title: const Text('Settings / Backup'), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen())); }),
          const Divider(),
          // 🔥 NEW: SAFE EXIT BUTTON
          ListTile(
            leading: const Icon(Icons.exit_to_app, color: Colors.red), 
            title: const Text('Safe Exit'), 
            onTap: () {
              if (Platform.isAndroid) {
                SystemNavigator.pop();
              } else {
                exit(0); // Force close for iOS (simulates swipe kill)
              }
            }
          ),
          const Divider(),
          ListTile(leading: const Icon(Icons.info_outline), title: const Text('About Us'), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (context) => const AboutScreen())); }),
        ],
      ),
    );
  }
}

// --- PROJECT LIST SCREEN ---
class ProjectListScreen extends StatefulWidget {
  const ProjectListScreen({super.key});
  @override
  State<ProjectListScreen> createState() => _ProjectListScreenState();
}

class _ProjectListScreenState extends State<ProjectListScreen> {
  List<Project> _allProjects = [];
  List<Project> _filteredProjects = [];
  Map<String, int> _inspectionCounts = {};
  Map<String, int> _cleanCounts = {};
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final projects = await ReportDatabase.loadProjects();
    for (var p in projects) {
      final reports = await ReportDatabase.loadReports(p.id);
      _inspectionCounts[p.id] = reports.where((r) => r.type == 'inspection').length;
      _cleanCounts[p.id] = reports.where((r) => r.type == 'clean').length;
    }
    setState(() { _allProjects = projects; _filteredProjects = projects; });
  }

  void _filterProjects(String query) {
    setState(() {
      _filteredProjects = _allProjects.where((p) => p.name.toLowerCase().contains(query.toLowerCase())).toList();
    });
  }

  void _createProject() {
    final nameCtrl = TextEditingController();
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("New Cx Project"),
      content: TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: "Project Name"), autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        ElevatedButton(onPressed: () {
          if (nameCtrl.text.isNotEmpty) {
            final newProj = Project(id: const Uuid().v4(), name: nameCtrl.text, lastModified: DateTime.now());
            setState(() { _allProjects.add(newProj); _filteredProjects = List.from(_allProjects); });
            ReportDatabase.saveProjects(_allProjects);
            Navigator.pop(context);
            _loadProjects();
          }
        }, child: const Text("Create")),
      ],
    ));
  }

  void _editProject(Project project) {
    final nameCtrl = TextEditingController(text: project.name);
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("Rename Project"),
      content: TextField(controller: nameCtrl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        ElevatedButton(onPressed: () {
          setState(() { project.name = nameCtrl.text; project.lastModified = DateTime.now(); });
          ReportDatabase.saveProjects(_allProjects);
          Navigator.pop(context);
        }, child: const Text("Save")),
      ],
    ));
  }

  void _deleteProject(Project project) {
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text("Delete Project?"),
      content: Text("Permanently delete '${project.name}' and all data?"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: () async {
          setState(() { _allProjects.removeWhere((p) => p.id == project.id); _filteredProjects = List.from(_allProjects); });
          await ReportDatabase.saveProjects(_allProjects);
          Navigator.pop(context);
        }, child: const Text("Delete", style: TextStyle(color: Colors.white))),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isSearching 
          ? TextField(controller: _searchController, autofocus: true, decoration: const InputDecoration(hintText: "Search Projects...", border: InputBorder.none, hintStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white, fontSize: 18), onChanged: _filterProjects)
          : const Text("Cx Pro - Projects"),
        actions: [IconButton(icon: Icon(_isSearching ? Icons.close : Icons.search), onPressed: () => setState(() { _isSearching = !_isSearching; if (!_isSearching) { _searchController.clear(); _filteredProjects = _allProjects; } }))],
      ),
      drawer: const AppDrawer(),
      body: _filteredProjects.isEmpty ? const Center(child: Text("No projects found.")) : ListView.builder(
        itemCount: _filteredProjects.length,
        itemBuilder: (context, index) {
          final proj = _filteredProjects[index];
          final iCount = _inspectionCounts[proj.id] ?? 0;
          final cCount = _cleanCounts[proj.id] ?? 0;
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
            child: ListTile(
              leading: const CircleAvatar(backgroundColor: Colors.indigo, child: Icon(Icons.business, color: Colors.white)),
              title: Text(proj.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text("$iCount Inspections • $cCount Clean Reports\nModified: ${DateFormat('dd/MM/yyyy').format(proj.lastModified)}", style: const TextStyle(fontSize: 12)),
              trailing: PopupMenuButton<String>(
                onSelected: (val) { if (val == 'edit') _editProject(proj); if (val == 'delete') _deleteProject(proj); },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit), title: Text("Rename"))),
                  const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete, color: Colors.red), title: Text("Delete"))),
                ],
              ),
              onTap: () async { await Navigator.push(context, MaterialPageRoute(builder: (context) => ReportListScreen(project: proj))); _loadProjects(); },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _createProject, label: const Text("New Site", style: TextStyle(color: Colors.white)), icon: const Icon(Icons.add_business, color: Colors.white), backgroundColor: Colors.indigo),
    );
  }
}

// --- REPORT LIST SCREEN ---
class ReportListScreen extends StatefulWidget {
  final Project project;
  const ReportListScreen({super.key, required this.project});
  @override
  State<ReportListScreen> createState() => _ReportListScreenState();
}

class _ReportListScreenState extends State<ReportListScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<InspectionReport> _allReports = [];
  List<InspectionReport> _filteredReports = [];
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() { if (!_tabController.indexIsChanging) setState(() {}); });
    _loadReports();
  }

  Future<void> _loadReports() async {
    final data = await ReportDatabase.loadReports(widget.project.id);
    setState(() { _allReports = data; _filteredReports = data; });
  }

  void _filterReports(String query) {
    setState(() {
      _filteredReports = _allReports.where((r) => r.itemName.toLowerCase().contains(query.toLowerCase()) || r.location.toLowerCase().contains(query.toLowerCase())).toList();
    });
  }

  void _createReport(String type) {
    final itemCtrl = TextEditingController();
    final locCtrl = TextEditingController();
    DateTime selDate = DateTime.now();
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDiag) => AlertDialog(
        title: Text(type == 'clean' ? "New Clean Report" : "New Inspection"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: itemCtrl, decoration: const InputDecoration(labelText: "Equipment Tag")),
          TextField(controller: locCtrl, decoration: const InputDecoration(labelText: "Location")),
          if (type == 'clean') ListTile(title: Text("Date: ${DateFormat('dd/MM/yyyy').format(selDate)}"), trailing: const Icon(Icons.calendar_today), onTap: () async {
            final p = await showDatePicker(context: context, initialDate: selDate, firstDate: DateTime(2020), lastDate: DateTime(2030));
            if (p != null) setDiag(() => selDate = p);
          }),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(onPressed: () {
            if (itemCtrl.text.isEmpty) return;
            final r = InspectionReport(id: const Uuid().v4(), projectId: widget.project.id, itemName: itemCtrl.text, location: locCtrl.text, type: type, createdAt: selDate, items: []);
            ReportDatabase.saveReport(r);
            Navigator.pop(ctx);
            _loadReports();
            Navigator.push(context, MaterialPageRoute(builder: (c) => EditorScreen(report: r, projectName: widget.project.name)));
          }, child: const Text("Start"))
        ],
      )),
    );
  }

  void _renameReport(InspectionReport report) {
    final itemCtrl = TextEditingController(text: report.itemName);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Rename"), content: TextField(controller: itemCtrl),
      actions: [ElevatedButton(onPressed: () { setState(() => report.itemName = itemCtrl.text); ReportDatabase.saveReport(report); Navigator.pop(ctx); }, child: const Text("Save"))],
    ));
  }

  void _deleteReport(InspectionReport report) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Delete?"), actions: [ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.red), onPressed: () { ReportDatabase.deleteReport(report.id); _loadReports(); Navigator.pop(ctx); }, child: const Text("Delete", style: TextStyle(color: Colors.white)))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final inspections = _filteredReports.where((r) => r.type == 'inspection').toList();
    final cleanReports = _filteredReports.where((r) => r.type == 'clean').toList();

    return Scaffold(
      appBar: AppBar(
        title: _isSearching 
          ? TextField(controller: _searchController, autofocus: true, decoration: const InputDecoration(hintText: "Search tag/room...", border: InputBorder.none, hintStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white), onChanged: _filterReports)
          : Text(widget.project.name),
        actions: [IconButton(icon: Icon(_isSearching ? Icons.close : Icons.search), onPressed: () => setState(() { _isSearching = !_isSearching; if (!_isSearching) { _searchController.clear(); _filteredReports = _allReports; } }))],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white, 
          unselectedLabelColor: Colors.white60,
          tabs: const [Tab(text: "Inspections"), Tab(text: "Clean Reports")]
        ),
      ),
      body: TabBarView(controller: _tabController, children: [
        _buildList(inspections, Colors.indigo, Icons.assignment),
        _buildList(cleanReports, Colors.teal, Icons.check_circle),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createReport(_tabController.index == 1 ? 'clean' : 'inspection'),
        label: Text(_tabController.index == 1 ? "Add Clean Report" : "Add Inspection", style: const TextStyle(color: Colors.white)), 
        backgroundColor: _tabController.index == 1 ? Colors.teal : Colors.indigo,
        icon: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildList(List<InspectionReport> list, Color col, IconData icon) {
    if (list.isEmpty) return const Center(child: Text("No records found."));
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (ctx, i) {
        final r = list[i];
        return ListTile(
          leading: Icon(icon, color: col),
          title: Text(r.itemName, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text("${r.location} • ${DateFormat('dd/MM/yyyy').format(r.createdAt)}"),
          trailing: PopupMenuButton<String>(
            onSelected: (v) { if (v == 'e') _renameReport(r); if (v == 'd') _deleteReport(r); },
            itemBuilder: (c) => [const PopupMenuItem(value: 'e', child: Text("Rename")), const PopupMenuItem(value: 'd', child: Text("Delete", style: TextStyle(color: Colors.red)))]
          ),
          onTap: () async { await Navigator.push(context, MaterialPageRoute(builder: (c) => EditorScreen(report: r, projectName: widget.project.name))); _loadReports(); },
        );
      },
    );
  }
}

// --- EDITOR SCREEN ---
class EditorScreen extends StatefulWidget {
  final InspectionReport report;
  final String projectName;
  const EditorScreen({super.key, required this.report, required this.projectName});
  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  final ImagePicker _picker = ImagePicker();
  bool _isProcessing = false;

  Future<void> _addPhoto() async {
    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(child: Wrap(children: [
        ListTile(leading: const Icon(Icons.camera_alt), title: const Text("Camera"), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
        ListTile(leading: const Icon(Icons.photo_library), title: const Text("Gallery"), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
      ])),
    );
    if (source == null) return;
    setState(() => _isProcessing = true);
    try {
      if (source == ImageSource.camera) {
        final img = await _picker.pickImage(source: ImageSource.camera);
        if (img != null) {
          final path = await ReportDatabase.saveCompressedImage(img);
          if (!mounted) return;
          final annotated = await Navigator.push(context, MaterialPageRoute(builder: (c) => AnnotationScreen(imageFile: File(path))));
          String finalPath = path;
          if (annotated != null && annotated is Uint8List) finalPath = await ReportDatabase.saveAnnotatedImage(annotated);
          setState(() => widget.report.items.add(ReportItem(imagePath: finalPath)));
        }
      } else {
        final imgs = await _picker.pickMultiImage();
        for (var img in imgs) {
          final path = await ReportDatabase.saveCompressedImage(img);
          setState(() => widget.report.items.add(ReportItem(imagePath: path)));
        }
      }
      ReportDatabase.saveReport(widget.report);
    } catch (e) { print(e); }
    setState(() => _isProcessing = false);
  }

  Future<void> _generatePdf() async {
    setState(() => _isProcessing = true);
    try {
      Uint8List? bytes;
      String name = "${widget.report.itemName}.pdf";
      if (widget.report.type == 'clean') { bytes = await _generateCorporateCleanReport(); } 
      else {
        int? grid = await showDialog<int>(context: context, builder: (ctx) => AlertDialog(title: const Text("Grid Layout"), content: Wrap(spacing: 10, children: [
          _gridOpt(ctx, 1, "Full", Icons.crop_portrait), _gridOpt(ctx, 2, "Half", Icons.view_stream), _gridOpt(ctx, 4, "4-Grid", Icons.grid_view), _gridOpt(ctx, 6, "Compact", Icons.view_module),
        ])));
        if (grid == null) { setState(() => _isProcessing = false); return; }
        bytes = await _generateInspectionReport(grid);
      }
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/$name').writeAsBytes(bytes!);
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (c) => PdfViewerScreen(pdfBytes: bytes!, fileName: name)));
    } catch (e) { print(e); }
    setState(() => _isProcessing = false);
  }

  Widget _gridOpt(BuildContext ctx, int val, String lab, IconData ic) => IconButton(icon: Column(children: [Icon(ic), Text(lab, style: const TextStyle(fontSize: 10))]), onPressed: () => Navigator.pop(ctx, val));

  Future<Uint8List> _generateCorporateCleanReport() async {
    final pdf = pw.Document();
    final font = await PdfGoogleFonts.robotoRegular();
    final bold = await PdfGoogleFonts.robotoBold();
    pw.MemoryImage? vantage; pw.MemoryImage? byes; pw.MemoryImage? sign;
    try { vantage = pw.MemoryImage((await rootBundle.load('assets/VANTAGE.png')).buffer.asUint8List()); } catch (_) {}
    try { byes = pw.MemoryImage((await rootBundle.load('assets/BYES.png')).buffer.asUint8List()); } catch (_) {}
    try { sign = pw.MemoryImage((await rootBundle.load('assets/sign.png')).buffer.asUint8List()); } catch (_) {}

    pdf.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(30),
      header: (ctx) => pw.Column(children: [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          if (vantage != null) pw.Image(vantage, height: 35),
          pw.Text("MXP13-Melegnano (MI) Italy", style: pw.TextStyle(font: bold, fontSize: 12)),
          if (byes != null) pw.Image(byes, height: 35),
        ]),
        pw.Divider(),
      ]),
      footer: (ctx) => pw.Column(children: [
        pw.Divider(),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(widget.report.itemName, style: pw.TextStyle(fontSize: 10)),
          pw.Text("Page ${ctx.pageNumber}", style: pw.TextStyle(fontSize: 10)),
        ])
      ]),
      build: (ctx) => [
        pw.SizedBox(height: 20),
        pw.Table(border: pw.TableBorder.all(), children: [
          pw.TableRow(children: [pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("Item Name:", style: pw.TextStyle(font: bold))), pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text(widget.report.itemName))]),
          pw.TableRow(children: [pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("Location:", style: pw.TextStyle(font: bold))), pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text(widget.report.location))]),
          pw.TableRow(children: [pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("Date:", style: pw.TextStyle(font: bold))), pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text(DateFormat('dd/MM/yyyy').format(widget.report.createdAt)))]),
        ]),
        pw.SizedBox(height: 20),
        _pdfGrid(widget.report.items),
        pw.SizedBox(height: 30),
        pw.Table(border: pw.TableBorder.all(), children: [
          pw.TableRow(children: [pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("VERIFIED BY:", style: pw.TextStyle(font: bold))), pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("BOUYGUES ITALIA"))]),
          pw.TableRow(children: [
            pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("Signature:", style: pw.TextStyle(font: bold))),
            pw.Container(height: 50, child: sign != null ? pw.Center(child: pw.Image(sign, height: 40)) : pw.Center(child: pw.Text("(Signed)"))),
          ]),
          pw.TableRow(children: [
            pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("Date & Location:", style: pw.TextStyle(font: bold))),
            pw.Padding(padding: const pw.EdgeInsets.all(5), child: pw.Text("${DateFormat('dd/MM/yyyy').format(widget.report.createdAt)} - Melegnano", style: pw.TextStyle(font: font))),
          ]),
        ]),
      ]
    ));
    return pdf.save();
  }

  Future<Uint8List> _generateInspectionReport(int perPage) async {
    final pdf = pw.Document();
    final bold = await PdfGoogleFonts.robotoBold();
    for (int i = 0; i < widget.report.items.length; i += perPage) {
      final chunk = widget.report.items.skip(i).take(perPage).toList();
      pdf.addPage(pw.Page(build: (ctx) => pw.Column(children: [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text("${widget.report.itemName} Inspection", style: pw.TextStyle(font: bold, fontSize: 18)),
          pw.Text(DateFormat('dd/MM/yyyy').format(widget.report.createdAt)),
        ]),
        pw.Divider(),
        pw.Expanded(child: _pdfGrid(chunk)),
      ])));
    }
    return pdf.save();
  }

  pw.Widget _pdfGrid(List<ReportItem> items) {
    return pw.GridView(crossAxisCount: 2, childAspectRatio: 1.0, children: items.map((it) => pw.Container(padding: const pw.EdgeInsets.all(5), child: pw.Column(children: [
      pw.Expanded(child: pw.Image(pw.MemoryImage(File(it.imagePath).readAsBytesSync()), fit: pw.BoxFit.contain)),
      pw.Text(it.heading.isEmpty ? "Observation" : it.heading, style: const pw.TextStyle(fontSize: 10)),
    ]))).toList());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.report.itemName), actions: [
        IconButton(icon: const Icon(Icons.sort), onPressed: () async {
          final sorted = await Navigator.push(context, MaterialPageRoute(builder: (c) => ReorderScreen(items: widget.report.items)));
          if (sorted != null) setState(() => widget.report.items = sorted);
        }),
        IconButton(icon: const Icon(Icons.picture_as_pdf), onPressed: _generatePdf),
      ]),
      body: Stack(children: [
        GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10),
          itemCount: widget.report.items.length,
          itemBuilder: (ctx, i) => GestureDetector(
            onTap: () => _editItem(i),
            child: Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: Image.file(File(widget.report.items[i].imagePath), fit: BoxFit.cover, cacheWidth: 300)),
              Padding(padding: const EdgeInsets.all(4), child: Text(widget.report.items[i].heading.isEmpty ? "No Title" : widget.report.items[i].heading, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ])),
          ),
        ),
        if (_isProcessing) const Center(child: CircularProgressIndicator()),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _addPhoto, icon: const Icon(Icons.add_a_photo, color: Colors.white), label: const Text("Add Photo", style: TextStyle(color: Colors.white)), backgroundColor: widget.report.type == 'clean' ? Colors.teal : Colors.indigo),
    );
  }

  void _editItem(int i) {
    final item = widget.report.items[i];
    final h = TextEditingController(text: item.heading);
    final c = TextEditingController(text: item.comment);
    showDialog(context: context, builder: (ctx) => AlertDialog(
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Image.file(File(item.imagePath), height: 150),
        TextField(controller: h, decoration: const InputDecoration(labelText: "Heading")),
        TextField(controller: c, decoration: const InputDecoration(labelText: "Comment")),
      ]),
      actions: [
        TextButton(onPressed: () { setState(() => widget.report.items.removeAt(i)); Navigator.pop(ctx); ReportDatabase.saveReport(widget.report); }, child: const Text("Delete", style: TextStyle(color: Colors.red))),
        ElevatedButton(onPressed: () { setState(() { item.heading = h.text; item.comment = c.text; }); Navigator.pop(ctx); ReportDatabase.saveReport(widget.report); }, child: const Text("Save"))
      ],
    ));
  }
}

class AnnotationScreen extends StatefulWidget {
  final File imageFile;
  const AnnotationScreen({super.key, required this.imageFile});
  @override
  State<AnnotationScreen> createState() => _AnnotationScreenState();
}

class _AnnotationScreenState extends State<AnnotationScreen> {
  final ImagePainterController _controller = ImagePainterController(color: Colors.red, strokeWidth: 4.0);
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Mark Issues"), actions: [IconButton(icon: const Icon(Icons.check), onPressed: () async { final img = await _controller.exportImage(); Navigator.pop(context, img); })]),
      body: ImagePainter.file(widget.imageFile, controller: _controller, scalable: true),
    );
  }
}

class PdfViewerScreen extends StatelessWidget {
  final Uint8List pdfBytes;
  final String fileName;
  const PdfViewerScreen({super.key, required this.pdfBytes, required this.fileName});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(fileName)),
      body: PdfPreview(build: (f) => pdfBytes, pdfFileName: fileName, canChangeOrientation: false, canDebug: false),
    );
  }
}

class ReorderScreen extends StatefulWidget {
  final List<ReportItem> items;
  const ReorderScreen({super.key, required this.items});
  @override
  State<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends State<ReorderScreen> {
  late List<ReportItem> _items;
  @override
  void initState() { super.initState(); _items = List.from(widget.items); }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Reorder"), leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context, _items))),
      body: ReorderableListView.builder(
        itemCount: _items.length,
        onReorder: (oldIdx, newIdx) { setState(() { if (newIdx > oldIdx) newIdx -= 1; _items.insert(newIdx, _items.removeAt(oldIdx)); }); },
        itemBuilder: (ctx, i) => ListTile(key: ValueKey(_items[i].imagePath), leading: Image.file(File(_items[i].imagePath), width: 50), title: Text(_items[i].heading), trailing: const Icon(Icons.drag_handle)),
      ),
    );
  }
}

class SavedReportsScreen extends StatefulWidget {
  const SavedReportsScreen({super.key});
  @override
  State<SavedReportsScreen> createState() => _SavedReportsScreenState();
}

class _SavedReportsScreenState extends State<SavedReportsScreen> {
  List<FileSystemEntity> _files = [];
  @override
  void initState() { super.initState(); _loadFiles(); }
  Future<void> _loadFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().where((e) => e.path.endsWith('.pdf')).toList();
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    setState(() => _files = files);
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Saved Outputs")),
      body: ListView.builder(
        itemCount: _files.length,
        itemBuilder: (ctx, i) {
          final f = _files[i];
          return Card(child: ListTile(
            leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
            title: Text(f.uri.pathSegments.last),
            trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await f.delete(); _loadFiles(); }),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => PdfViewerScreen(pdfBytes: File(f.path).readAsBytesSync(), fileName: f.uri.pathSegments.last))),
          ));
        },
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _q = AppSettings.quality;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text("Backup & Sync", style: TextStyle(fontWeight: FontWeight.bold)),
        ListTile(leading: const Icon(Icons.cloud_upload), title: const Text("Create Backup"), onTap: () => BackupManager.createBackup(context)),
        ListTile(leading: const Icon(Icons.restore), title: const Text("Restore Data"), onTap: () => BackupManager.restoreBackup(context)),
        
        // 🔥 RESCUE ORPHANS: Tap this if you deleted a project but want reports back
        ListTile(leading: const Icon(Icons.build, color: Colors.orange), title: const Text("Link Orphans to Current Project"), subtitle: const Text("Recover hidden reports"), onTap: () async {
          final projects = await ReportDatabase.loadProjects();
          if (projects.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Create a Project first!"))); return; }
          int count = await ReportDatabase.rescueOrphanReports(projects.first.id);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Rescued $count reports to ${projects.first.name}")));
        }),

        const Divider(),
        const Text("Image Compression"),
        Slider(value: _q.toDouble(), min: 50, max: 100, divisions: 5, label: "$_q%", onChanged: (v) { setState(() => _q = v.toInt()); AppSettings.setQuality(_q); }),
      ]),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("About Us")),
      body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 150, height: 150, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.indigo, width: 4)),
          child: ClipOval(child: Image.asset('assets/me.jpg', fit: BoxFit.cover, errorBuilder: (c, e, s) => const Icon(Icons.person, size: 80)))),
        const SizedBox(height: 20),
        const Text("Ashique K K", style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text("Commissioning Engineer", style: TextStyle(fontSize: 18, color: Colors.grey)),
        const Text("Version 2.0 (Pro Edition)", style: TextStyle(color: Colors.grey)),
      ])),
    );
  }
}