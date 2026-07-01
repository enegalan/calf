import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shadcn_ui/shadcn_ui.dart';

const baseUrl = 'http://localhost:8080';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _message = 'Loading...';

  @override
  void initState() {
    super.initState();
    _loadHello();
  }

  Future<void> _loadHello() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/hello'));
      if (!mounted) {
        return;
      }
      if (response.statusCode == 200) {
        setState(() => _message = response.body);
      } else {
        setState(() => _message = 'Error: ${response.statusCode}');
      }
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _message = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        _message,
        style: ShadTheme.of(context).textTheme.large,
      ),
    );
  }
}
