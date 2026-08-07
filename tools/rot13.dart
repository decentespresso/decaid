import 'dart:io';

void main(List<String> args) {
  String input;

  if (args.isNotEmpty) {
    input = args.join(' ');
  } else {
    input = stdin.readLineSync() ?? '';
  }

  if (input.isEmpty) {
    stderr.writeln(
      'Usage: dart tools/rot13.dart <raw-token>\n'
      '   or: echo "<token>" | dart tools/rot13.dart',
    );
    exit(1);
  }

  stdout.writeln(_rot13(input));
}

String _rot13(String input) {
  final buf = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    buf.writeCharCode(_rotate(input.codeUnitAt(i)));
  }
  return buf.toString();
}

int _rotate(int c) {
  if (c >= 65 && c <= 90) return ((c - 65 + 13) % 26) + 65;
  if (c >= 97 && c <= 122) return ((c - 97 + 13) % 26) + 97;
  return c;
}
