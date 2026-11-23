// ============================================================
// Supabase Edge Function: term-acceptance
// Aceite digital de termos: envia o e-mail com o link individual e registra o aceite.
//
// Publicar:  supabase functions deploy term-acceptance --no-verify-jwt
// Segredos:  supabase secrets set RESEND_API_KEY=... MAIL_FROM="TI <ti@seudominio.com>"
//            (opcional) ALLOWED_APP_URL=https://seu-sistema.netlify.app  MAIL_REPLY_TO=ti@seudominio.com
//
// Por que existe: o aceite só pode ser marcado por esta função (usa a chave de serviço,
// que nunca sai do servidor). Quem tem apenas a chave pública do projeto NÃO consegue
// marcar um termo como aceito: a tabela term_acceptances não aceita UPDATE por ela.
// O token do link nunca é guardado (só o hash SHA-256) e, no envio por e-mail, nunca
// volta para o painel: só quem recebe o e-mail tem o link.
// ============================================================

type Row = Record<string, any>;

export interface Deps {
  env: (k: string) => string | undefined;
  now: () => number;
  sha256: (s: string) => Promise<string>;
  randomToken: () => string;
  sendMail: (m: { from: string; to: string; subject: string; html: string; replyTo?: string }) => Promise<void>;
  db: {
    accById: (id: string) => Promise<Row | null>;
    accByTokenHash: (h: string) => Promise<Row | null>;
    termById: (id: string) => Promise<Row | null>;
    /** atualiza e devolve a linha; se onlyIfStatus for informado, só atualiza se o status ainda for esse */
    updateAcc: (id: string, patch: Row, onlyIfStatus?: string) => Promise<Row | null>;
    cancelOthers: (termId: string, exceptId: string) => Promise<void>;
  };
}

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: Row) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8' } });

const MESSAGES: Record<string, string> = {
  invalid_token: 'Link inválido ou não encontrado.',
  expired: 'Este link expirou. Peça à área de TI um novo envio.',
  cancelled: 'Esta solicitação foi cancelada pela área de TI.',
  already_accepted: 'Este termo já foi aceito.',
  name_required: 'Digite seu nome completo para confirmar o aceite.',
  not_pending: 'Esta solicitação não está mais pendente.',
  too_soon: 'Aguarde 1 minuto antes de reenviar.',
  email_not_configured: 'O envio de e-mail ainda não foi configurado no servidor (RESEND_API_KEY e MAIL_FROM).',
  invalid_email: 'E-mail do destinatário inválido.',
  app_url_not_allowed: 'Endereço do sistema não permitido.',
  email_failed: 'Não foi possível enviar o e-mail.',
};
const fail = (status: number, error: string, extra: Row = {}) => json(status, { ok: false, error, message: MESSAGES[error] || error, ...extra });

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string));
const fmtBR = (ms: number) => new Intl.DateTimeFormat('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' }).format(new Date(ms));
const kindLabel = (t: Row) => (t.kind === 'devolucao' ? 'Termo de devolução' : 'Termo de responsabilidade');

function effectiveStatus(acc: Row, now: number): string {
  if (acc.status === 'pendente' && acc.expires_at_ms && now > Number(acc.expires_at_ms)) return 'expirado';
  return acc.status;
}

function emailHtml(o: { name: string; kind: string; number: string; equipment: string; org: string; link: string; expires: string }) {
  return `<!doctype html><html><body style="margin:0;padding:0;background:#f3f4f8;font-family:Arial,Helvetica,sans-serif;color:#1b1f2d">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f8;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:10px;padding:28px">
<tr><td style="font-size:18px;font-weight:bold;padding-bottom:12px">${esc(o.kind)} — aceite digital</td></tr>
<tr><td style="font-size:14px;line-height:1.6;padding-bottom:14px">Olá, <strong>${esc(o.name)}</strong>.<br>A área de TI${o.org ? ' da <strong>' + esc(o.org) + '</strong>' : ''} enviou o <strong>${esc(o.kind.toLowerCase())} nº ${esc(o.number)}</strong>, referente ao equipamento <strong>${esc(o.equipment)}</strong>, para o seu aceite digital.</td></tr>
<tr><td style="font-size:14px;line-height:1.6;padding-bottom:18px">Clique no botão abaixo, leia o termo e, se estiver de acordo, clique em <strong>ACEITAR</strong>.</td></tr>
<tr><td align="center" style="padding-bottom:18px"><a href="${esc(o.link)}" style="background:#2F6FD0;color:#ffffff;text-decoration:none;font-weight:bold;font-size:15px;padding:13px 26px;border-radius:8px;display:inline-block">Ler e aceitar o termo</a></td></tr>
<tr><td style="font-size:12px;line-height:1.6;color:#666;padding-bottom:6px">Este link é pessoal e válido até <strong>${esc(o.expires)}</strong>. Não o encaminhe a outras pessoas. Ao aceitar, são registrados a data e a hora, o endereço IP e o dispositivo usado.</td></tr>
<tr><td style="font-size:12px;line-height:1.6;color:#666">Se o botão não funcionar, copie este endereço no navegador:<br><span style="word-break:break-all">${esc(o.link)}</span><br><br>Se você não reconhece esta solicitação, ignore este e-mail.</td></tr>
</table></td></tr></table></body></html>`;
}

export async function handle(req: Request, d: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return fail(405, 'method_not_allowed');
  let b: Row;
  try { b = await req.json(); } catch { return fail(400, 'invalid_json'); }
  const now = d.now();

  // ---------- leitura pública (página de aceite) ----------
  if (b.action === 'get') {
    const token = String(b.token || '');
    if (token.length < 20) return fail(404, 'invalid_token');
    const acc = await d.db.accByTokenHash(await d.sha256(token));
    if (!acc) return fail(404, 'invalid_token');
    const term = await d.db.termById(acc.term_id);
    if (!term) return fail(404, 'invalid_token');
    let status = effectiveStatus(acc, now);
    if (status === 'expirado' && acc.status !== 'expirado') await d.db.updateAcc(acc.id, { status: 'expirado' }, 'pendente');
    return json(200, {
      ok: true, status,
      term: { number: term.number, kind: term.kind || 'entrega', kindLabel: kindLabel(term), equipmentLabel: term.equipment_label, orgName: term.org_name, pdfUrl: term.file_url },
      recipientName: acc.recipient_name, expiresAt: acc.expires_at_ms, acceptedAt: acc.accepted_at_ms || null,
      acceptedName: acc.accepted_name || '', verificationCode: acc.verification_code || '',
    });
  }

  // ---------- aceite ----------
  if (b.action === 'accept') {
    const token = String(b.token || '');
    const name = String(b.name || '').trim().replace(/\s+/g, ' ');
    if (token.length < 20) return fail(404, 'invalid_token');
    if (name.length < 5) return fail(400, 'name_required');
    const tokenHash = await d.sha256(token);
    const acc = await d.db.accByTokenHash(tokenHash);
    if (!acc) return fail(404, 'invalid_token');
    if (acc.status === 'aceito') return fail(409, 'already_accepted', { acceptedAt: acc.accepted_at_ms, verificationCode: acc.verification_code });
    if (acc.status === 'cancelado') return fail(410, 'cancelled');
    if (effectiveStatus(acc, now) === 'expirado') return fail(410, 'expired');
    const ip = (req.headers.get('cf-connecting-ip') || req.headers.get('x-forwarded-for') || req.headers.get('x-real-ip') || '').split(',')[0].trim();
    const ua = String(b.userAgent || req.headers.get('user-agent') || '').slice(0, 300);
    const code = (await d.sha256(`${acc.id}|${acc.doc_sha256}|${now}|${tokenHash}`)).slice(0, 12).toUpperCase().replace(/(.{4})(?=.)/g, '$1-');
    const updated = await d.db.updateAcc(acc.id, {
      status: 'aceito', accepted_at_ms: now, accepted_name: name, accepted_ip: ip, accepted_ua: ua, verification_code: code,
    }, 'pendente');
    if (!updated) return fail(409, 'already_accepted');
    return json(200, { ok: true, status: 'aceito', acceptedAt: now, acceptedName: name, verificationCode: code });
  }

  // ---------- envio (painel) ----------
  if (b.action === 'send') {
    const acc = await d.db.accById(String(b.acceptanceId || ''));
    if (!acc) return fail(404, 'invalid_token');
    if (acc.status !== 'pendente') return fail(409, 'not_pending');
    if (acc.expires_at_ms && now > Number(acc.expires_at_ms)) return fail(410, 'expired');
    if (acc.last_sent_at_ms && now - Number(acc.last_sent_at_ms) < 60_000) return fail(429, 'too_soon');
    const mode = b.mode === 'manual' ? 'manual' : 'email';
    const appUrl = String(b.appUrl || '').replace(/[?#].*$/, '');
    if (!/^https?:\/\//i.test(appUrl)) return fail(400, 'app_url_not_allowed');
    const allowed = d.env('ALLOWED_APP_URL');
    if (allowed && !appUrl.startsWith(allowed.replace(/\/+$/, ''))) return fail(400, 'app_url_not_allowed');
    let mailKey = '', from = '';
    if (mode === 'email') {
      mailKey = d.env('RESEND_API_KEY') || ''; from = d.env('MAIL_FROM') || '';
      if (!mailKey || !from) return fail(503, 'email_not_configured');
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(acc.recipient_email || ''))) return fail(400, 'invalid_email');
    }
    const term = await d.db.termById(acc.term_id);
    if (!term) return fail(404, 'invalid_token');
    const token = d.randomToken();
    const link = `${appUrl}?aceite=${encodeURIComponent(token)}&p=${encodeURIComponent(d.env('SUPABASE_URL') || '')}`;
    const patch = { token_hash: await d.sha256(token), delivery: mode, sent_at_ms: acc.sent_at_ms || now, last_sent_at_ms: now, send_count: Number(acc.send_count || 0) + 1 };
    const saved = await d.db.updateAcc(acc.id, patch, 'pendente');
    if (!saved) return fail(409, 'not_pending');
    if (mode === 'email') {
      try {
        await d.sendMail({
          from, to: String(acc.recipient_email), replyTo: d.env('MAIL_REPLY_TO') || undefined,
          subject: `Aceite digital — ${kindLabel(term)} nº ${term.number}`,
          html: emailHtml({ name: acc.recipient_name || '', kind: kindLabel(term), number: term.number, equipment: term.equipment_label || '', org: term.org_name || '', link, expires: acc.expires_at_ms ? fmtBR(Number(acc.expires_at_ms)) : '—' }),
        });
      } catch (e) {
        await d.db.updateAcc(acc.id, { token_hash: null, send_count: Number(acc.send_count || 0), last_sent_at_ms: acc.last_sent_at_ms ?? null }, 'pendente');
        return fail(502, 'email_failed', { detail: String((e as Error)?.message || e).slice(0, 300) });
      }
      await d.db.cancelOthers(acc.term_id, acc.id);   // só cancela as anteriores depois que o novo envio deu certo
      return json(200, { ok: true, delivery: 'email', sentAt: now });   // o link NÃO volta para o painel
    }
    await d.db.cancelOthers(acc.term_id, acc.id);
    return json(200, { ok: true, delivery: 'manual', sentAt: now, link });
  }

  // ---------- cancelar solicitação (painel) ----------
  if (b.action === 'cancel') {
    const acc = await d.db.accById(String(b.acceptanceId || ''));
    if (!acc) return fail(404, 'invalid_token');
    const done = await d.db.updateAcc(acc.id, { status: 'cancelado' }, 'pendente');
    return done ? json(200, { ok: true }) : fail(409, 'not_pending');
  }

  return fail(400, 'invalid_action');
}

// ---------- ligação com o Supabase (só roda dentro do Deno) ----------
declare const Deno: any;
if (typeof Deno !== 'undefined' && Deno.serve) {
  const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const one = async (q: any) => { const { data, error } = await q.maybeSingle(); if (error) throw error; return data as Row | null; };
  const deps: Deps = {
    env: (k) => Deno.env.get(k),
    now: () => Date.now(),
    sha256: async (s) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))).map((x) => x.toString(16).padStart(2, '0')).join(''),
    randomToken: () => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
    sendMail: async (m) => {
      const res = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: m.from, to: [m.to], subject: m.subject, html: m.html, ...(m.replyTo ? { reply_to: m.replyTo } : {}) }),
      });
      if (!res.ok) throw new Error(`Resend ${res.status}: ${(await res.text()).slice(0, 200)}`);
    },
    db: {
      accById: (id) => one(sb.from('term_acceptances').select('*').eq('id', id)),
      accByTokenHash: (h) => one(sb.from('term_acceptances').select('*').eq('token_hash', h)),
      termById: (id) => one(sb.from('terms').select('*').eq('id', id)),
      updateAcc: async (id, patch, onlyIfStatus) => {
        let q = sb.from('term_acceptances').update(patch).eq('id', id);
        if (onlyIfStatus) q = q.eq('status', onlyIfStatus);
        return one(q.select());
      },
      cancelOthers: async (termId, exceptId) => {
        const { error } = await sb.from('term_acceptances').update({ status: 'cancelado' }).eq('term_id', termId).eq('status', 'pendente').neq('id', exceptId);
        if (error) throw error;
      },
    },
  };
  Deno.serve((req: Request) => handle(req, deps).catch((e) => json(500, { ok: false, error: 'internal', message: String((e as Error)?.message || e) })));
}
