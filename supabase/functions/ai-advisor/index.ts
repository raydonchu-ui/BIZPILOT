// BizPilot AI Advisor — Supabase Edge Function (Deno).
//
// Flow: authenticate the caller with their own JWT -> meter the request
// (permission + plan feature + monthly limit enforced in SQL) -> load figures
// that were computed in the database (advisor_context) -> ask Claude to explain
// them. The model never sees raw tables and never takes actions.
//
// Secrets (set with `supabase secrets set`): ANTHROPIC_API_KEY (optional - without
// it the function returns mode "fallback" and the app shows rule-based answers),
// AI_MODEL (optional, default claude-opus-5-5). SUPABASE_URL / SUPABASE_ANON_KEY
// are provided by the platform.
import Anthropic from 'npm:@anthropic-ai/sdk';
import { createClient } from 'npm:@supabase/supabase-js@2';

const MODEL = Deno.env.get('AI_MODEL') ?? 'claude-opus-5-5';
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const SYSTEM = `You are the BizPilot AI Advisor, a practical business advisor for small retail shops in Cameroon.
You answer the shop owner's question using ONLY the JSON business data provided in the user message.
That data was calculated by BizPilot from the shop's recorded transactions.

Rules:
- Never invent numbers, products, suppliers, customers or transactions. If the data does not contain what is needed, say so plainly and say what the owner would need to record.
- Always state the reporting period you analysed (from the "period" field).
- Money is in FCFA (XAF). Write amounts like "125 000 FCFA". Do not convert currencies.
- Separate clearly: **Facts** (figures taken from the data), **Estimates** (anything projected or inferred, labelled as such), and **Recommendations** (practical next steps).
- Mention important limitations from "data_quality" and the insights' "limitations" (for example estimated opening costs, few transactions, short history).
- Do not call a product bad only because it sells slowly: consider its margin, stock age and whether it was out of stock.
- Revenue is not profit. Recorded sales are not cash received.
- You cannot place orders, change prices, issue refunds or make payments. Suggest actions; the owner decides.
- Be concise and concrete: short sections, bullet points, at most about 300 words unless the question needs more.
- Answer in the language requested.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const auth = req.headers.get('Authorization');
  if (!auth) return json({ error: 'not_authenticated' }, 401);
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });

  let body: { business_id?: string; question?: string; from?: string; to?: string; lang?: string };
  try { body = await req.json(); } catch { return json({ error: 'invalid_request' }, 400); }
  const { business_id, question, from, to } = body;
  const lang = body.lang === 'fr' ? 'French' : 'English';
  if (!business_id || !question || !from || !to) return json({ error: 'invalid_request' }, 400);

  // Metering + authorization (permission, plan feature, monthly quota, rate limit).
  const begin = await supabase.rpc('ai_begin_query', { p_business: business_id, p_question: question, p_from: from, p_to: to });
  if (begin.error) return json({ error: begin.error.message, details: begin.error.details }, 403);
  const queryId = begin.data as string;

  const ctx = await supabase.rpc('advisor_context', { p_business: business_id, p_from: from, p_to: to });
  if (ctx.error) {
    await supabase.rpc('ai_complete_query', { p_query: queryId, p_status: 'failed', p_answer: null, p_model: null, p_error: ctx.error.message });
    return json({ error: ctx.error.message }, 400);
  }

  const apiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!apiKey) {
    await supabase.rpc('ai_complete_query', { p_query: queryId, p_status: 'fallback', p_answer: null, p_model: null, p_error: 'not_configured' });
    return json({ mode: 'fallback', reason: 'not_configured', context: ctx.data });
  }

  try {
    const client = new Anthropic({ apiKey });
    const response = await client.beta.messages.create({
      model: MODEL,
      max_tokens: 16000,
      output_config: { effort: 'medium' },
      // On a safety-classifier decline the API re-runs the request on a suitable fallback model.
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      system: SYSTEM,
      messages: [{
        role: 'user',
        content: `Answer in ${lang}.\n\nBusiness data (JSON):\n${JSON.stringify(ctx.data)}\n\nQuestion from the shop owner:\n${question}`,
      }],
    } as any);

    if (response.stop_reason === 'refusal') {
      await supabase.rpc('ai_complete_query', { p_query: queryId, p_status: 'failed', p_answer: null, p_model: response.model, p_error: 'refusal' });
      return json({ mode: 'fallback', reason: 'refusal', context: ctx.data });
    }
    const answer = response.content.filter((b: any) => b.type === 'text').map((b: any) => b.text).join('\n').trim();
    await supabase.rpc('ai_complete_query', {
      p_query: queryId, p_status: 'completed', p_answer: answer, p_model: response.model,
      p_input_tokens: response.usage?.input_tokens ?? null, p_output_tokens: response.usage?.output_tokens ?? null,
    });
    return json({ mode: 'ai', answer, model: response.model, period: (ctx.data as any)?.period, query_id: queryId });
  } catch (e) {
    const msg = e instanceof Anthropic.APIError ? `${e.status ?? ''} ${e.message}` : String(e);
    await supabase.rpc('ai_complete_query', { p_query: queryId, p_status: 'failed', p_answer: null, p_model: MODEL, p_error: msg });
    return json({ mode: 'fallback', reason: 'ai_error', context: ctx.data });
  }
});
