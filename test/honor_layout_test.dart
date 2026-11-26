import 'dart:ui' show Offset;

import 'package:coach_companion/models/honor_layout.dart';
import 'package:coach_companion/widgets/text_look.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('leeres/kaputtes Layout ergibt Standard', () {
    expect(HonorLayout.decode(null).isEmpty, isTrue);
    expect(HonorLayout.decode('kein json').isEmpty, isTrue);
    expect(HonorLayout().isEmpty, isTrue);
    // Nur Standard-Werte gesetzt → weiterhin leer.
    final l = HonorLayout();
    l.format('urkunde').setItem('name', const HonorElementEdit());
    expect(l.isEmpty, isTrue);
    expect(l.format('urkunde').items, isEmpty);
  });

  test('JSON-Roundtrip behält Texte, Umbrüche, Position und Stil', () {
    final l = HonorLayout();
    l.texts['occasion'] = '100\nMEISTERSCHAFTSPIELE';
    l.texts['name'] = 'Furkan';
    final u = l.format('urkunde');
    u.setItem(
      'stats',
      const HonorElementEdit(
        off: Offset(4, -12.5),
        scale: 1.4,
        rot: 0.2,
        hidden: true,
        look: TextLook(font: 'anton', color: '#C9A24B'),
      ),
    );
    u.free.add(
      HonorFreeText(id: '1', text: 'Danke!\nFür alles', x: 0.3, y: 0.8),
    );

    final back = HonorLayout.decode(l.encode());
    expect(back.texts['occasion'], '100\nMEISTERSCHAFTSPIELE');
    final e = back.format('urkunde').item('stats');
    expect(e.off, const Offset(4, -12.5));
    expect(e.scale, 1.4);
    expect(e.rot, 0.2);
    expect(e.hidden, isTrue);
    expect(e.look?.font, 'anton');
    expect(e.look?.color, '#C9A24B');
    final f = back.format('urkunde').free.single;
    expect(f.text, 'Danke!\nFür alles');
    expect(f.x, 0.3);
    expect(f.y, 0.8);
    expect(f.itemId, 'free:1');
  });

  test('Vorlage nimmt den Namen nicht mit', () {
    final l = HonorLayout();
    l.texts['name'] = 'Furkan-Mustafa Bulut';
    l.texts['ulabel'] = 'EHRENURKUNDE';
    l.format('post').setItem('photo', const HonorElementEdit(scale: 2));
    l.photoSlot = 'action';
    l.photoData = 'data:image/jpeg;base64,AAAA';
    final back = HonorLayout.decode(l.encode());
    expect(back.photoSlot, 'action');
    expect(back.photoData, 'data:image/jpeg;base64,AAAA');
    final t = l.forTemplate();
    expect(t.photoSlot, isNull);
    expect(t.photoData, isNull);
    expect(t.texts.containsKey('name'), isFalse);
    expect(t.texts['ulabel'], 'EHRENURKUNDE');
    expect(t.format('post').item('photo').scale, 2);
    // Original unverändert.
    expect(l.texts['name'], 'Furkan-Mustafa Bulut');
  });

  test('Größe wird begrenzt', () {
    const e = HonorElementEdit();
    expect(e.copyWith(scale: 99).scale, HonorElementEdit.maxScale);
    expect(e.copyWith(scale: 0).scale, HonorElementEdit.minScale);
  });
}
