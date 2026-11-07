// Supabase Edge Function: ai-image
// Bearbeitet die komplette (gerenderte) Sportgrafik mit Google Gemini Image
// nach einem frei formulierten Wunsch und gibt das bearbeitete Bild zurueck.
//
// Body: { image: <base64 ohne data:-Prefix>, mime: string, prompt: string }
// Antwort: { image: <base64>, mime: string }  (oder Fehlertext mit Status)
//
// Benoetigte Secrets (supabase secrets set ...):
//   GEMINI_API_KEY       = dein Google-AI-Studio API-Key
//   GEMINI_IMAGE_MODEL   = optional, Standard: gemini-2.5-flash-image
// SUPABASE_URL / SUPABASE_ANON_KEY liefert Supabase automatisch.
//
// Deploy:  supabase functions deploy ai-image

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") ?? "";
const MODEL = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

// Feste Leitplanke: die Grafik soll als Ganzes bearbeitet werden, aber die
// Kern-Infos (Spielstand, Namen, Logos) moeglichst erhalten bleiben.
// Data-URL-Prefix (data:image/...;base64,) abschneiden; liefert mime + data.
function stripDataUrl(s: string): { mime: string; data: string } {
  const m = s.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.*)$/s);
  if (m) return { mime: m[1], data: m[2] };
  return { mime: "image/png", data: s };
}

// Leitplanken-Text je Modus. 'background' = nur kreativer Hintergrund (ohne
// Logos/Text), 'compose' = ganze Grafik aus den mitgeschickten Bausteinen,
// 'overlay' = Deko-Ebene (KI-Look) auf Schwarz/Magenta (Body-Feld `key`),
// 'cutout' = Person freistellen.
function guardText(
  mode: string,
  aspect: string,
  roles: string[],
  key = "black",
  retry = false,
): string {
  if (mode === "overlay") {
    // Deko-Ebene („KI-Look") ueber einer fertigen Grafik. Die App legt sie
    // darueber: bei Schwarz per Screen-Mischung (leuchtend), bei Magenta wird
    // der Grund transparent gemacht (freigestellt).
    const ground = key === "magenta"
      ? "exakt einfarbig reines MAGENTA (#FF00FF). Verwende Magenta/Pink " +
        "NIRGENDS in der Deko selbst"
      : "exakt einfarbig reines SCHWARZ (#000000). Die Deko soll hell, " +
        "farbig und leuchtend sein (dunkle Deko-Teile werden unsichtbar)";
    return (
      "Erzeuge NUR eine dekorative Overlay-Ebene fuer ein Fussball-Social-" +
      "Media-Poster im Seitenverhaeltnis " + aspect + ". Die Deko liegt NUR " +
      "an den Raendern und in den Ecken (Rahmen-Wirkung); die MITTE (ca. 60 % " +
      "der Flaeche) bleibt KOMPLETT LEER, damit Spieler, Texte und Logos frei " +
      "bleiben. KEINE Texte, Buchstaben, Zahlen, Logos, Wappen, Gesichter oder " +
      "Personen. Der Hintergrund ist " + ground + " – ohne Verlauf, ohne " +
      "Struktur, ohne Schatten auf dem Grund. Das beiliegende einfarbige Bild " +
      "ist die LEERE LEINWAND: behalte exakt dieses Format und diese " +
      "Grundfarbe bei und male die Deko darauf. Hochwertig, plakativ, " +
      "professioneller Poster-Look. Thema/Motiv: "
    );
  }
  if (mode === "cutout" && key === "magenta") {
    // Gemini kann keine echte Transparenz liefern → Motiv auf reines Magenta,
    // die App macht Magenta danach transparent (zuverlaessig, auch fuer Haare).
    // Englisch: Bildbearbeitung folgt englischen Anweisungen zuverlaessiger.
    if (retry) {
      // Zweiter Versuch (erster hat den Hintergrund nicht ersetzt): kurz und
      // unmissverstaendlich.
      return (
        "Edit this photo. Replace the ENTIRE background with one flat, solid " +
        "pure magenta color (#FF00FF). Keep only the subject below exactly " +
        "as it is. The output must clearly differ from the input: no trace " +
        "of the original background may remain. Subject to keep: "
      );
    }
    return (
      "Edit the attached photo: remove the background completely. Keep ONLY " +
      "the subject described below, unchanged (same pose, face, hair, " +
      "clothes, colors, size and position in the frame, same aspect ratio). " +
      "Fill EVERYTHING else with one flat, solid, pure magenta color " +
      "(#FF00FF, RGB 255/0/255) – also the gaps between arms and body, " +
      "between the legs and around the hair, and the whole image border. " +
      "No gradient, no shadow, no floor, nothing of the original background " +
      "(sky, grass, street, wall, fence, other people) may remain. Clean, " +
      "precise edges. Do not use magenta inside the subject. " +
      "Subject to keep (German): "
    );
  }
  if (mode === "cutout") {
    return (
      "Stelle die auf dem beiliegenden Bild gezeigte Person (Fussballspieler) " +
      "exakt frei: entferne den KOMPLETTEN Hintergrund vollstaendig und gib " +
      "NUR die Person als Bild mit transparentem Hintergrund (Alpha-Kanal, " +
      "PNG) zurueck. Fuege KEINEN neuen Hintergrund, KEINE Farbflaeche, KEINE " +
      "Schatten und KEINE zusaetzlichen Elemente hinzu. Lasse die Person " +
      "unveraendert (gleiche Haltung, Kleidung, Farben, Gesicht); schneide nur " +
      "sauber an den Raendern frei. Zusatz des Nutzers: "
    );
  }
  if (mode === "background") {
    return (
      "Erzeuge NUR ein kreatives, hochwertiges Hintergrund-/Designbild fuer " +
      "eine Fussball-Sportgrafik im Seitenverhaeltnis " + aspect + ". KEINE " +
      "Logos, KEINE Texte, KEINE Zahlen, KEINE Wappen einfuegen. Lasse ruhige, " +
      "gleichmaessige Flaechen, damit spaeter Logos und Texte gut lesbar " +
      "darueber passen. Die beiliegenden Bilder dienen NUR als Farb- und Stil-" +
      "Inspiration (Vereinsfarben, Stimmung). Wunsch des Nutzers: "
    );
  }
  return (
    "Du gestaltest eine Fussball-Sportgrafik (Social-Media-Post) im " +
    "Seitenverhaeltnis " + aspect + ". Dir liegen mehrere Bilder bei; ihre " +
    "Rollen in Reihenfolge: " + roles.join(", ") + ". Baue daraus eine " +
    "ansprechende, kreative Grafik. WICHTIG: Uebernimm die mitgeschickten " +
    "Vereins- und Sponsorenlogos EXAKT und unveraendert - kopiere sie 1:1, " +
    "zeichne sie NICHT neu, aendere KEINE Formen, Buchstaben, Schrift oder " +
    "Farben im Logo. Du darfst hoechstens den weissen Kasten/Rahmen um ein " +
    "Logo entfernen (freistellen), niemals das Logo selbst veraendern. " +
    "Schreibe Teamnamen, Datum und Uhrzeit EXAKT wie angegeben (keine " +
    "erfundenen Zusaetze wie 'F.C.', keine Tippfehler); Datum und Uhrzeit " +
    "gross und prominent platzieren. Wunsch des Nutzers: "
  );
}

Deno.serve(async (req) => {
  try {
    if (!GEMINI_API_KEY) {
      return new Response("GEMINI_API_KEY fehlt (Secret setzen)", {
        status: 500,
      });
    }
    const authHeader = req.headers.get("Authorization") ?? "";
    const asUser = createClient(SUPABASE_URL, ANON, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData } = await asUser.auth.getUser();
    if (!userData?.user?.id) {
      return new Response("unauthorized", { status: 401 });
    }

    // Serverseitige Freigabe (Admin steuert pro Benutzer). NUR sperren, wenn der
    // Nutzer AUSDRUECKLICH deaktiviert ist. Fehlt die Pruef-Funktion (Migration
    // stage45 nicht angewendet) oder gibt es einen Fehler, NICHT blocken –
    // sonst waere die KI ohne die Migration komplett tot.
    const { data: aiOk, error: aiErr } = await asUser.rpc("has_ai_access", {
      kind: "image",
    });
    if (!aiErr && aiOk === false) {
      return new Response(
        "KI (Bild) ist für dich nicht freigeschaltet",
        { status: 403 },
      );
    }

    const body = (await req.json()) as Record<string, unknown>;
    const mode = String(body.mode ?? "compose");
    const aspect = String(body.aspect ?? "9:16");

    // Bilder sammeln: images[] (mehrere Bausteine) bevorzugt, sonst Einzelbild.
    type Img = { mime: string; data: string; role: string };
    const imgs: Img[] = [];
    const rawImages = Array.isArray(body.images) ? body.images : [];
    for (const it of rawImages) {
      const o = it as Record<string, unknown>;
      const raw = String(o.data ?? "");
      if (!raw) continue;
      const s = stripDataUrl(raw);
      imgs.push({
        mime: o.mime ? String(o.mime) : s.mime,
        data: s.data,
        role: String(o.role ?? "image"),
      });
    }
    if (imgs.length === 0 && body.image) {
      const s = stripDataUrl(String(body.image));
      imgs.push({
        mime: body.mime ? String(body.mime) : s.mime,
        data: s.data,
        role: "base",
      });
    }
    const prompt = String(body.prompt ?? "").trim();
    // Hintergrund-Modus darf OHNE Referenzbild laufen (reine Text-zu-Bild-
    // Gestaltung – keine Logos noetig). Andere Modi brauchen ein Bild.
    if (imgs.length === 0 && mode !== "background" && mode !== "overlay") {
      return new Response("kein Bild", { status: 400 });
    }
    if (!prompt) return new Response("kein Wunsch", { status: 400 });

    const key = String(body.key ?? "black");
    const retry = body.retry === true;
    const text =
      guardText(mode, aspect, imgs.map((i) => i.role), key, retry) + prompt;
    const parts = [
      ...imgs.map((i) => ({
        inline_data: { mime_type: i.mime, data: i.data },
      })),
      { text },
    ];

    const url =
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}` +
      `:generateContent?key=${GEMINI_API_KEY}`;
    // Zeitlimit: lieber sauber mit 504 antworten, als dass die Verbindung
    // (Function-Limit) hart abbricht und die App nur „Verbindung weg" sieht.
    let resp: Response;
    try {
      resp = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        signal: AbortSignal.timeout(110_000),
        body: JSON.stringify({
          contents: [{ role: "user", parts }],
          // Freistellen: immer ein Bild zurueck (keine reine Text-Antwort).
          ...(mode === "cutout"
            ? { generationConfig: { responseModalities: ["IMAGE"] } }
            : {}),
        }),
      });
    } catch (e) {
      const name = (e as Error)?.name ?? "";
      if (name === "TimeoutError" || name === "AbortError") {
        return new Response(
          "timeout: Die KI hat nicht rechtzeitig geantwortet",
          { status: 504 },
        );
      }
      return new Response(
        "Gemini nicht erreichbar: " + ((e as Error)?.message ?? e),
        { status: 503 },
      );
    }
    if (!resp.ok) {
      const t = await resp.text();
      return new Response("Gemini-Fehler: " + t, { status: 502 });
    }
    const json = await resp.json();
    const outParts =
      (json?.candidates?.[0]?.content?.parts ?? []) as Array<
        Record<string, unknown>
      >;
    let outData = "";
    let outMime = "image/png";
    for (const p of outParts) {
      const inline = (p.inline_data ?? p.inlineData) as
        | Record<string, unknown>
        | undefined;
      if (inline && typeof inline.data === "string") {
        outData = inline.data as string;
        outMime = String(inline.mime_type ?? inline.mimeType ?? "image/png");
        break;
      }
    }
    if (!outData) {
      return new Response("Kein Bild von der KI erhalten", { status: 502 });
    }
    return Response.json({ image: outData, mime: outMime });
  } catch (e) {
    return new Response("error: " + ((e as Error)?.message ?? e), {
      status: 500,
    });
  }
});
