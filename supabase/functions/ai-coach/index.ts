// Supabase Edge Function: ai-coach
// Erzeugt/dokumentiert Trainings-Übungen mit der Anthropic (Claude) API.
// Modi (Body `mode`):
//   generate | bullets | video | photo
// Gibt ein striktes JSON-Objekt (Übungs-Entwurf) zurück.
//
// Benötigte Secrets (supabase secrets set ...):
//   ANTHROPIC_API_KEY = dein Anthropic-API-Key (sk-ant-...)
//   AI_MODEL          = optional, Standard: claude-opus-5-5
//                       (guenstiger: claude-haiku-5-5 oder claude-sonnet-5-5)
// SUPABASE_URL / SUPABASE_ANON_KEY liefert Supabase automatisch.
//
// Deploy:  supabase functions deploy ai-coach

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const MODEL = Deno.env.get("AI_MODEL") ?? "claude-opus-5-5";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const SYSTEM = `Du bist ein erfahrener Fussball-Co-Trainer und Trainingsplaner.
Erstelle bzw. dokumentiere EINE Trainingsuebung als striktes JSON-Objekt nach
diesem Schema (keine weiteren Felder, keine Erklaerung, kein Markdown):
{
 "title": string,
 "categories": string[],        // Trainingsarten, z.B. "Taktik","Standards"
 "aufbau": string,              // Feldaufbau / Organisation
 "ablauf": string,              // Ablauf der Uebung Schritt fuer Schritt
 "coachingPoints": string,      // worauf der Trainer achtet
 "varianten": string,           // Steigerungen / Varianten
 "minPlayers": number|null,     // benoetigte Spieler
 "needsGoalkeeper": boolean,
 "durationMin": number|null,
 "material": string,            // Huetchen, Baelle, Leibchen ...
 "diagram": {                   // Skizze; Koordinaten x,y zwischen 0 und 1
   "field": "full"|"half"|"box",
   "elements": [
     { "type": "player"|"cone"|"goal"|"ball"|"arrow"|"zone"|"text",
       "x": number, "y": number,
       "x2": number, "y2": number,   // nur bei arrow (Ende) / zone (2. Ecke)
       "color": string,              // optional, Hex z.B. "#C62828" fuer Gegner
       "label": string }             // optional (Rueckennummer / Text)
   ]
 }
}
Zeichne eine sinnvolle, nachvollziehbare Skizze (Spieler, Huetchen, Tore, Baelle,
Laufwege als Pfeile, Zonen). Antworte AUSSCHLIESSLICH mit dem JSON-Objekt.`;

function textContent(s: string) {
  return [{ type: "text", text: s }];
}

function buildMessages(body: Record<string, unknown>) {
  const mode = String(body.mode ?? "generate");
  const players = body.players ?? "";
  const gk = body.goalkeepers ?? "";
  const cats = Array.isArray(body.categories)
    ? (body.categories as string[]).join(", ")
    : String(body.categories ?? "");
  const ctx =
    `Kontext: ${players} Feldspieler, ${gk} Torhueter` +
    (cats ? `, Trainingsart: ${cats}` : "");

  if (mode === "bullets") {
    return [
      {
        role: "user",
        content: textContent(
          `Mach aus diesen Stichpunkten eine vollstaendige Uebung inkl. Skizze.\n` +
            `${ctx}\nStichpunkte:\n${String(body.bullets ?? "")}`,
        ),
      },
    ];
  }
  if (mode === "video") {
    return [
      {
        role: "user",
        content: textContent(
          `Erstelle eine Uebung aus diesen Video-Infos (nur Metadaten, nicht ` +
            `das Videobild).\n${ctx}\nTitel: ${String(body.title ?? "")}\n` +
            `Beschreibung: ${String(body.description ?? "")}\n` +
            `Transkript/Notizen: ${String(body.transcript ?? "")}`,
        ),
      },
    ];
  }
  if (mode === "photo") {
    const dataUrl = String(body.image ?? "");
    const m = dataUrl.match(/^data:(image\/[a-zA-Z]+);base64,(.*)$/s);
    const mediaType = m ? m[1] : "image/jpeg";
    const data = m ? m[2] : dataUrl;
    return [
      {
        role: "user",
        content: [
          {
            type: "image",
            source: { type: "base64", media_type: mediaType, data },
          },
          {
            type: "text",
            text:
              `Dies ist das Foto einer handgezeichneten Fussball-Uebung. ` +
              `Analysiere die Skizze und dokumentiere die Uebung vollstaendig ` +
              `im JSON-Schema, inkl. rekonstruiertem diagram (Spieler/Huetchen/` +
              `Tore/Baelle/Laufwege als Positionen). ${ctx}\n` +
              `Zusatzinfo: ${String(body.hint ?? "")}`,
          },
        ],
      },
    ];
  }
  // generate
  return [
    {
      role: "user",
      content: textContent(
        `Schlage EINE passende Trainingsuebung vor (inkl. Skizze).\n${ctx}\n` +
          `Fokus/Wunsch: ${String(body.focus ?? "")}\n` +
          `Zieldauer: ${String(body.duration ?? "")} Minuten`,
      ),
    },
  ];
}

function extractJson(text: string): unknown {
  // Codefences entfernen und das erste JSON-Objekt herausschneiden.
  let t = text.replace(/```json/gi, "").replace(/```/g, "").trim();
  const start = t.indexOf("{");
  const end = t.lastIndexOf("}");
  if (start >= 0 && end > start) t = t.substring(start, end + 1);
  return JSON.parse(t);
}

Deno.serve(async (req) => {
  try {
    if (!ANTHROPIC_API_KEY) {
      return new Response("ANTHROPIC_API_KEY fehlt (Secret setzen)", {
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
    const messages = buildMessages(body);

    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 4000,
        system: SYSTEM,
        messages,
      }),
    });
    if (!resp.ok) {
      const t = await resp.text();
      return new Response("Anthropic-Fehler: " + t, { status: 502 });
    }
    const json = await resp.json();
    const parts = (json.content ?? []) as Array<{ type: string; text?: string }>;
    const text = parts
      .filter((p) => p.type === "text")
      .map((p) => p.text ?? "")
      .join("\n");
    const draft = extractJson(text);
    return Response.json({ exercise: draft });
  } catch (e) {
    return new Response("error: " + ((e as Error)?.message ?? e), {
      status: 500,
    });
  }
});
