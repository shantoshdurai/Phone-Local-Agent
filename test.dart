void main() {
  try {
    throw Exception("Test");
  } catch (e) {
    print('Error: $e');
  }
}
