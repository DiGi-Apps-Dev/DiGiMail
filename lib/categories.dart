import 'models.dart';

/// Categorie dell'Assistente. Sono riconosciute da parole nell'oggetto e nel
/// mittente: è un'approssimazione, non legge il contenuto di ogni email.
enum Cat { viaggi, pacchi, fatture, intrattenimento, coupon, abbonamenti }

const Map<Cat, String> catLabel = {
  Cat.viaggi: 'Viaggi',
  Cat.pacchi: 'Pacchi',
  Cat.fatture: 'Fatture e ricevute',
  Cat.intrattenimento: 'Intrattenimento',
  Cat.coupon: 'Coupon e offerte',
  Cat.abbonamenti: 'Abbonamenti',
};

final Map<Cat, RegExp> _rules = {
  Cat.viaggi: RegExp(
    r'\b(volo|voli|biglietto del treno|biglietti? (aere|treno)|prenotazione (hotel|volo|camera|viaggio)|check-?in|boarding|itinerario|hotel|booking\.com|airbnb|trenitalia|italo|easyjet|ryanair|lufthansa|swiss|sbb|flixbus|noleggio auto|crociera|flight|reservation|itinerary)\b',
    caseSensitive: false,
  ),
  Cat.pacchi: RegExp(
    r'\b(spedizione|spedito|tracking|tracciamento|consegna|in consegna|corriere|pacco|ordine .{0,12}(spedito|in arrivo)|dhl|ups|gls|brt|fedex|poste ?italiane|swiss ?post|la posta svizzera|sda|your (order|package)|shipped|delivery)\b',
    caseSensitive: false,
  ),
  Cat.fatture: RegExp(
    r'\b(fattura|fatture|ricevuta|ricevute|pagamento|estratto conto|bolletta|scadenza pagamento|addebito|invoice|receipt|payment|order confirmation|conferma d.?ordine|rata)\b',
    caseSensitive: false,
  ),
  Cat.intrattenimento: RegExp(
    r'\b(biglietti? (concerto|cinema|teatro|evento|spettacolo|partita)|ticketone|eventim|ticket|cinema|concerto|spettacolo|teatro|netflix|spotify|prime video|disney)\b',
    caseSensitive: false,
  ),
  Cat.coupon: RegExp(
    r'\b(coupon|codice (sconto|promo)|sconto|sconti|offerta|offerte|promozione|saldi|% ?(di )?sconto|promo|black friday|cyber monday|voucher)\b',
    caseSensitive: false,
  ),
};

/// Categorie a cui appartiene un messaggio (può essere più di una).
Set<Cat> categoriesOf(Msg m) {
  final text = '${m.subject} ${m.fromName} ${m.fromAddr}';
  final out = <Cat>{};
  for (final e in _rules.entries) {
    if (e.value.hasMatch(text)) out.add(e.key);
  }
  if (m.listUnsub.isNotEmpty) out.add(Cat.abbonamenti);
  return out;
}

/// «Principali» o «Altro»: ciò che sembra una comunicazione automatica va in Altro.
bool isOther(Msg m) {
  if (m.listUnsub.isNotEmpty) return true;
  final a = m.fromAddr.toLowerCase();
  return a.startsWith('noreply') ||
      a.startsWith('no-reply') ||
      a.startsWith('donotreply') ||
      a.startsWith('newsletter') ||
      a.startsWith('mailer') ||
      a.startsWith('notifica');
}
