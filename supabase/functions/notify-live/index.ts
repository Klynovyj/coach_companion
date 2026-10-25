// Supabase Edge Function: notify-live
// Schickt eine FCM-Push an alle Team-Mitglieder (außer dem Auslöser), wenn ein
// Spiel live geht. Wird von der App aufgerufen (setMatchStatus(live)).
//
// Benötigte Secrets (supabase secrets set ...):
//   FCM_SERVICE_ACCOUNT  = Inhalt der Firebase-Service-Account-JSON (ganze Datei)
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY liefert Supabase
// automatisch.
//
// Deploy:  supabase functions deploy notify-live

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SA = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "{}");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

function b64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === "string"
    ? new TextEncoder().encode(data)
    : new Uint8Array(data);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claim = {
    iss: SA.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claim))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(SA.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${b64url(sig)}`;
  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body:
      `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const json = await resp.json();
  if (!json.access_token) throw new Error("OAuth: " + JSON.stringify(json));
  return json.access_token as string;
}

Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const { team_id, match_id, opponent } = await req.json();
    if (!team_id) return new Response("team_id fehlt", { status: 400 });

    // Aufrufer verifizieren (muss Trainer/Admin des Teams sein).
    const asUser = createClient(SUPABASE_URL, ANON, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData } = await asUser.auth.getUser();
    const uid = userData?.user?.id;
    if (!uid) return new Response("unauthorized", { status: 401 });

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE);
    const { data: member } = await admin.from("team_members")
      .select("role").eq("team_id", team_id).eq("user_id", uid).maybeSingle();
    const { data: team } = await admin.from("teams")
      .select("created_by").eq("id", team_id).maybeSingle();
    const isTrainer = member?.role === "trainer" || team?.created_by === uid;
    if (!isTrainer) return new Response("forbidden", { status: 403 });

    // Tokens aller Mitglieder außer dem Auslöser.
    const { data: members } = await admin.from("team_members")
      .select("user_id").eq("team_id", team_id);
    const userIds = (members ?? [])
      .map((m: { user_id: string }) => m.user_id)
      .filter((id: string) => id !== uid);
    if (userIds.length === 0) {
      return Response.json({ sent: 0 });
    }
    const { data: tokens } = await admin.from("device_tokens")
      .select("token").in("user_id", userIds);
    const list = (tokens ?? []).map((t: { token: string }) => t.token);
    if (list.length === 0) return Response.json({ sent: 0 });

    const accessToken = await getAccessToken();
    const url =
      `https://fcm.googleapis.com/v1/projects/${SA.project_id}/messages:send`;
    let sent = 0;
    for (const token of list) {
      const resp = await fetch(url, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token,
            notification: {
              title: "Live-Spiel läuft",
              body: `vs ${opponent ?? "Gegner"}`,
            },
            data: {
              match_id: String(match_id ?? ""),
              team_id: String(team_id),
            },
            android: { priority: "high" },
          },
        }),
      });
      if (resp.ok) {
        sent++;
      } else if (resp.status === 404 || resp.status === 400) {
        // Ungültiges/abgelaufenes Token aufräumen.
        await admin.from("device_tokens").delete().eq("token", token);
      }
    }
    return Response.json({ sent });
  } catch (e) {
    return new Response("error: " + ((e as Error)?.message ?? e), {
      status: 500,
    });
  }
});
