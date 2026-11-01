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
// Logos/Text), 'compose' = ganze Grafik aus den mitgeschickten Bausteinen.
function guardText(mode: string, aspect: string, roles: string[]): string {
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
    if (imgs.length === 0 && mode !== "background") {
      return new Response("kein Bild", { status: 400 });
    }
    if (!prompt) return new Response("kein Wunsch", { status: 400 });

    const text = guardText(mode, aspect, imgs.map((i) => i.role)) + prompt;
    const parts = [
      ...imgs.map((i) => ({
        inline_data: { mime_type: i.mime, data: i.data },
      })),
      { text },
    ];

    const url =
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}` +
      `:generateContent?key=${GEMINI_API_KEY}`;
    const resp = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts }],
      }),
    });
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
