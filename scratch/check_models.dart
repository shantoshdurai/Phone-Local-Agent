import 'package:openai_dart/openai_dart.dart';
import 'dart:io';

void main() async {
  final apiKey = 'AIzaSyD3u99DxHO7c1HDKBDwZUZxbNW5G_f93qg';
  final client = OpenAIClient(
    apiKey: apiKey,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
  );

  try {
    print('Listing models...');
    final response = await client.listModels();
    for (var model in response.data) {
      print('Model: ${model.id}');
    }
  } catch (e) {
    print('Error: $e');
  }
}
