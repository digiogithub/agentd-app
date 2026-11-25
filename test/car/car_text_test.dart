import 'package:agentd_app/src/car/car_text.dart';
import 'package:agentd_app/src/core/contracts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('matchSpokenOption', () {
    const yesNo = ['Yes', 'Yes, and don\'t ask again', 'No, and tell Claude what to do differently'];

    test('number, digit or ordinal', () {
      expect(matchSpokenOption('2', yesNo), 1);
      expect(matchSpokenOption('dos', yesNo), 1);
      expect(matchSpokenOption('la segunda', yesNo), 1);
      expect(matchSpokenOption('Opción tres', yesNo), 2);
      expect(matchSpokenOption('cuatro', yesNo), isNull);
    });

    test('yes and no in Spanish', () {
      expect(matchSpokenOption('Sí', yesNo), 0);
      expect(matchSpokenOption('vale', yesNo), 0);
      expect(matchSpokenOption('no', yesNo), 2);
      expect(matchSpokenOption('rechaza', yesNo), 2);
    });

    test('label or a distinctive part of it, accents ignored', () {
      const opts = ['Migración en caliente', 'Ventana de mantenimiento'];
      expect(matchSpokenOption('ventana de mantenimiento', opts), 1);
      expect(matchSpokenOption('migracion', opts), 0);
      expect(matchSpokenOption('en caliente por favor', opts), isNull);
      expect(matchSpokenOption('mañana', opts), isNull);
    });

    test('ambiguous or empty answers name nothing', () {
      expect(matchSpokenOption('', yesNo), isNull);
      expect(matchSpokenOption('and', yesNo), isNull);
      expect(matchSpokenOption('sí', const []), isNull);
    });
  });

  test('speakable names code and tables and drops markup', () {
    const text = '⏺ He terminado **todo**. Ver https://x.dev/a\n'
        '$kChatCodeFence\nfunc main() {}\n$kChatCodeFence\n'
        '│ a │ b │\n│ 1 │ 2 │\n'
        '- Tests en `verde`';
    expect(speakable(text), 'He terminado todo. Ver un enlace\n(bloque de código)\n(tabla)\nTests en verde');
  });

  test('speakable cuts long text on a word', () {
    final s = speakable(List.filled(400, 'palabra').join(' '), limit: 50);
    expect(s.length, lessThanOrEqualTo(51));
    expect(s, endsWith('palabra…'));
  });

  test('conclusion and last lines', () {
    const items = [
      ChatItem(role: ChatRole.user, text: 'Haz los tests'),
      ChatItem(role: ChatRole.agent, text: 'Primero miro.'),
      ChatItem(role: ChatRole.tool, title: 'Bash', text: 'go test', meta: 'ok 12 tests'),
      ChatItem(role: ChatRole.agent, text: 'Listo: todo pasa.\n\nSiguiente paso: el despliegue.'),
      ChatItem(role: ChatRole.system, text: '✻ Brewed for 8s'),
    ];
    expect(conclusionOf(items), 'Listo: todo pasa.\n\nSiguiente paso: el despliegue.');
    expect(conclusionOf(const []), isNull);
    expect(lastLinesOf(items, 3), ['Listo: todo pasa.', 'Siguiente paso: el despliegue.', '✻ Brewed for 8s']);
    expect(lastLinesOf(items, 100).take(3), ['> Haz los tests', 'Primero miro.', 'Bash: ok 12 tests']);
  });

  test('spokenOptions', () {
    expect(spokenOptions(const ['Sí', 'No']), '1, Sí. 2, No.');
  });
}
