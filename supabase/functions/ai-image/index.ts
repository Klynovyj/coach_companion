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
const GUARD =
  "Du bearbeitest eine fertige Fussball-Sportgrafik (Social-Media-Post). " +
  "Setze den folgenden Wunsch des Nutzers zu Bild und Design um und gib das " +
  "bearbeitete Bild im selben Seitenverhaeltnis zurueck. Erhalte dabei den " +
  "Spielstand, die Teamnamen, Zahlen und Logos moeglichst originalgetreu und " +
  "gut lesbar; veraendere sie nicht inhaltlich. Wunsch: ";

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

    const body = (await req.json()) as Record<string, unknown>;
    let data = String(body.image ?? "");
    // Falls doch eine data:-URL kommt: Prefix abschneiden.
    const m = data.match(/^data:(image\/[a-zA-Z]+);base64,(.*)$/s);
    let mime = String(body.mime ?? "image/png");
    if (m) {
      mime = m[1];
      data = m[2];
    }
    const prompt = String(body.prompt ?? "").trim();
    if (!data) return new Response("kein Bild", { status: 400 });
    if (!prompt) return new Response("kein Wunsch", { status: 400 });

    const url =
      `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}` +
      `:generateContent?key=${GEMINI_API_KEY}`;
    const resp = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        contents: [
          {
            role: "user",
            parts: [
              { inline_data: { mime_type: mime, data } },
              { text: GUARD + prompt },
            ],
          },
        ],
      }),
    });
    if (!resp.ok) {
      const t = await resp.text();
      return new Response("Gemini-Fehler: " + t, { status: 502 });
    }
    const json = await resp.json();
    const parts =
      (json?.candidates?.[0]?.content?.parts ?? []) as Array<
        Record<string, unknown>
      >;
    let outData = "";
    let outMime = "image/png";
    for (const p of parts) {
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
