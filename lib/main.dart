import "package:flutter/material.dart";
import "screens/video_list_screen.dart";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BiliMergeApp());
}

class BiliMergeApp extends StatelessWidget {
  const BiliMergeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "BiliMerge",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const VideoListScreen(),
    );
  }
}
