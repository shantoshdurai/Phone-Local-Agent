import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'screens/home_screen.dart';
import 'screens/chat_screen.dart';
import 'services/model_downloader_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env").catchError((_) {});
  
  final downloader = ModelDownloaderService();
  final b15 = await downloader.isModelDownloaded("qwen2.5-1.5b-instruct-q4_k_m.gguf");
  final b05 = await downloader.isModelDownloaded("qwen2.5-0.5b-instruct-q4_k_m.gguf");
  
  String? initialModel;
  if (b15) {
    initialModel = "qwen2.5-1.5b-instruct-q4_k_m.gguf";
  } else if (b05) {
    initialModel = "qwen2.5-0.5b-instruct-q4_k_m.gguf";
  }

  runApp(MyApp(initialModel: initialModel));
}

class MyApp extends StatelessWidget {
  final String? initialModel;
  const MyApp({super.key, this.initialModel});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Local Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: initialModel != null ? ChatScreen(modelFileName: initialModel!) : const HomeScreen(),
    );
  }
}
