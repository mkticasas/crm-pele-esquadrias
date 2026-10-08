// iMarcas · Edge Function "webhook-lead"
// Recebe um lead (formulário, Make/Zapier, anúncio) e joga no CRM, distribuindo pro vendedor.
// Publicar no Supabase do cliente: Edge Functions → Deploy a new function → nome: webhook-lead
// → colar este código → Deploy. Depois, em Details, DESLIGAR "Verify JWT".
// Uso: POST https://<projeto>.supabase.co/functions/v1/webhook-lead?token=<token do webhook>

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// lê "a.b.c" dentro do payload (aceita campos aninhados)
const pick = (obj: any, path?: string) =>
  !path ? undefined : path.split(".").reduce((o, k) => (o == null ? undefined : o[k]), obj);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ success: false, error: "Use POST" }, 405);

  const token = new URL(req.url).searchParams.get("token");
  if (!token) return json({ success: false, error: "Token ausente" }, 400);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const { data: wh } = await db.from("webhooks").select("*").eq("token", token).maybeSingle();
  if (!wh || !wh.active) return json({ success: false, error: "Webhook inválido ou desativado" }, 404);

  let body: any = {};
  try {
    const ct = req.headers.get("content-type") || "";
    body = ct.includes("application/json") ? await req.json() : Object.fromEntries(new URLSearchParams(await req.text()));
  } catch { return json({ success: false, error: "Corpo inválido" }, 400); }

  const map = wh.field_map || { name: "name", phone: "phone", email: "email" };
  const name = String(pick(body, map.name || "name") ?? "").trim();
  const phone = String(pick(body, map.phone || "phone") ?? "").trim();
  if (!name && !phone) return json({ success: false, error: "Lead sem nome e sem telefone" }, 400);

  // escolhe o vendedor
  let seller_id: string | null = null;
  if (wh.distribution === "fixed" && wh.fixed_seller_id) {
    seller_id = wh.fixed_seller_id;
  } else {
    const { data: ativos } = await db.from("sellers").select("id").eq("status", "active").order("created_at");
    if (ativos && ativos.length) {
      const i = ativos.findIndex((s: any) => s.id === wh.last_seller_id);
      seller_id = ativos[(i + 1) % ativos.length].id;
    }
  }

  const lead = {
    name: name || "Sem nome",
    phone,
    email: String(pick(body, map.email || "email") ?? "").trim() || null,
    notes: map.notes ? String(pick(body, map.notes) ?? "").trim() || null : null,
    campaign: map.campaign ? String(pick(body, map.campaign) ?? "").trim() || null : null,
    origin: wh.origin || null,
    source: wh.name,
    seller_id,
    stage: "new",
    webhook_token: token,
  };

  const { data: novo, error } = await db.from("leads").insert(lead).select("id").single();
  if (error) return json({ success: false, error: error.message }, 500);

  await db.from("webhooks")
    .update({ leads_count: (wh.leads_count || 0) + 1, last_seller_id: seller_id ?? wh.last_seller_id })
    .eq("id", wh.id);

  return json({ success: true, lead_id: novo.id, seller_id });
});
