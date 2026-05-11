import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/model_downloader_service.dart';
import '../services/agent_service.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ModelDownloaderService _downloader = ModelDownloaderService();
  final AgentService _agent = AgentService();

  bool _is15BDownloaded = false;
  bool _is05BDownloaded = false;
  
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadSpeed = '';
  String _downloadedStr = '';
  String _totalStr = '';
  String _downloadingModel = '';

  final String _url15B = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf";
  final String _url05B = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf";
  
  final String _file15B = "qwen2.5-1.5b-instruct-q4_k_m.gguf";
  final String _file05B = "qwen2.5-0.5b-instruct-q4_k_m.gguf";

  @override
  void initState() {
    super.initState();
    _checkModels();
  }

  Future<void> _checkModels() async {
    final b15 = await _downloader.isModelDownloaded(_file15B);
    final b05 = await _downloader.isModelDownloaded(_file05B);
    setState(() {
      _is15BDownloaded = b15;
      _is05BDownloaded = b05;
    });
  }

  void _startDownload(String modelType) {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadSpeed = 'Starting...';
      _downloadingModel = modelType;
    });

    final url = modelType == '1.5B' ? _url15B : _url05B;
    final file = modelType == '1.5B' ? _file15B : _file05B;

    _downloader.downloadModel(
      url: url,
      fileName: file,
      onProgress: (progress, speed, downloaded, total) {
        if (mounted) {
          setState(() {
            _downloadProgress = progress;
            _downloadSpeed = speed;
            _downloadedStr = downloaded;
            _totalStr = total;
          });
        }
      },
      onComplete: () {
        if (mounted) {
          setState(() {
            _isDownloading = false;
          });
          _checkModels();
        }
      },
      onError: (err) {
        if (mounted) {
          setState(() {
            _isDownloading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        }
      },
    );
  }

  void _cancelDownload() {
    _downloader.cancelDownload();
    setState(() {
      _isDownloading = false;
    });
  }

  Future<void> _startChat(String modelType) async {
    final fileName = modelType == '1.5B' ? _file15B : _file05B;
    Navigator.pushAndRemoveUntil(
      context, 
      MaterialPageRoute(builder: (context) => ChatScreen(modelFileName: fileName)),
      (route) => false
    );
  }

  Widget _buildPerformanceEstimate() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.speed_rounded, color: Colors.blueAccent),
              const SizedBox(width: 8),
              Text('Device Performance Assessment', style: GoogleFonts.outfit(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          Text('Local AI depends heavily on your device\'s RAM and CPU.', style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 8),
          const Text('• Qwen 2.5 1.5B: Recommended for devices with 8GB+ RAM. Expected Speed: 5-15 tokens/sec.', style: TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 4),
          const Text('• Qwen 2.5 0.5B (Lite): Runs well on 4GB+ RAM. Expected Speed: 15-30+ tokens/sec.', style: TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildModelCard(String title, String desc, bool isDownloaded, String type) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: GoogleFonts.outfit(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              if (isDownloaded)
                const Icon(Icons.check_circle_rounded, color: Colors.green, size: 20)
            ],
          ),
          const SizedBox(height: 8),
          Text(desc, style: TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 16),
          if (_isDownloading && _downloadingModel == type)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: _downloadProgress, backgroundColor: Colors.white10, valueColor: const AlwaysStoppedAnimation<Color>(Colors.white)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('$_downloadSpeed - ${(_downloadProgress * 100).toStringAsFixed(1)}%', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    Text('$_downloadedStr / $_totalStr', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _cancelDownload,
                    child: const Text('Cancel', style: TextStyle(color: Colors.redAccent)),
                  ),
                )
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isDownloading ? null : () {
                  if (isDownloaded) {
                    _startChat(type);
                  } else {
                    _startDownload(type);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDownloaded ? Colors.blueAccent : Colors.white,
                  foregroundColor: isDownloaded ? Colors.white : Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                child: Text(isDownloaded ? 'Start Chat' : 'Download Model', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('Local Agent Setup', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Welcome to Fully Offline AI', style: GoogleFonts.outfit(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('This agent runs 100% locally on your device. No cloud APIs, no privacy risks. Please download an AI model to begin.', style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.5)),
            const SizedBox(height: 24),
            _buildPerformanceEstimate(),
            const SizedBox(height: 32),
            _buildModelCard(
              'Qwen 2.5 - 1.5B (Primary)', 
              'Highly capable, complex reasoning, better tool usage. Recommended for modern devices. Download Size: ~1.2 GB.', 
              _is15BDownloaded, 
              '1.5B'
            ),
            _buildModelCard(
              'Qwen 2.5 - 0.5B (Lite)', 
              'Extremely fast, lower memory footprint. Recommended for older devices or battery saving. Download Size: ~400 MB.', 
              _is05BDownloaded, 
              '0.5B'
            ),
          ],
        ),
      ),
    );
  }
}
