// ============================================================
// Supabase Edge Function: user-admin
// Gestão de usuários do sistema (SÓ para administrador): criar usuário, trocar senha e excluir.
// Isso precisa da chave secreta do Supabase, por isso roda aqui no servidor e nunca no navegador.
//
// Como publicar (sem instalar nada):
//   Supabase -> Edge Functions -> Deploy a new function -> Via Editor
//   Nome: user-admin   |   cole TODO este arquivo   |   Deploy
//   Em Settings da função, deixe "Verify JWT" DESLIGADO: a própria função confere
//   se quem chamou é um administrador ativo logado.
// Não precisa criar nenhum segredo: a URL e a chave de serviço o Supabase já entrega.
// ============================================================

export const MODULES = ['dashboard', 'equipments', 'movements', 'terms', 'registry', 'infra', 'planning'];
export const LEVELS = ['none', 'view', 'edit'];

export interface Profile { role: string; active: boolean }
export interface Deps {
  getCaller(token: string): Promise<{ id: string } | null>;
  getProfile(id: string): Promise<Profile | null>;
  countOtherActiveAdmins(exceptId: string): Promise<number>;
  createUser(a: { email: string; password: string; name: string }): Promise<{ id?: string; error?: string }>;
  updateProfile(id: string, patch: Record<string, unknown>): Promise<string | null>;
  setPassword(id: string, password: string): Promise<string | null>;
  deleteUser(id: string): Promise<string | null>;
}
export interface Req { method: string; headers: Record<string, string>; body: any }
export interface Res { status: number; body: Record<string, unknown> }

const fail = (status: number, error: string, message: string): Res => ({ status, body: { ok: false, error, message } });
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/** só aceita módulos e níveis conhecidos; o resto é descartado */
export function cleanPermissions(p: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (p && typeof p === 'object') {
    for (const m of MODULES) {
      const v = (p as Record<string, unknown>)[m];
      if (typeof v === 'string' && LEVELS.includes(v) && v !== 'none') out[m] = v;
    }
  }
  return out;
}

export async function handle(req: Req, d: Deps): Promise<Res> {
  if (req.method !== 'POST') return fail(405, 'method_not_allowed', 'Use POST.');
  const auth = req.headers['authorization'] || req.headers['Authorization'] || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return fail(401, 'unauthorized', 'Faça login novamente.');
  const caller = await d.getCaller(token);
  if (!caller) return fail(401, 'unauthorized', 'Sessão inválida ou expirada. Faça login novamente.');
  const me = await d.getProfile(caller.id);
  if (!me || !me.active || me.role !== 'admin') return fail(403, 'forbidden', 'Só administradores podem gerenciar usuários.');

  const b = req.body && typeof req.body === 'object' ? req.body : {};
  const action = String(b.action || '');

  if (action === 'create') {
    const email = String(b.email || '').trim().toLowerCase();
    const password = String(b.password || '');
    const name = String(b.name || '').trim() || email.split('@')[0];
    const role = b.role === 'admin' ? 'admin' : 'user';
    if (!EMAIL.test(email)) return fail(400, 'invalid_email', 'Informe um e-mail válido.');
    if (password.length < 8) return fail(400, 'weak_password', 'A senha precisa ter pelo menos 8 caracteres.');
    const created = await d.createUser({ email, password, name });
    if (created.error || !created.id) {
      const exists = /already|registered|exists|duplicate/i.test(created.error || '');
      return exists ? fail(409, 'email_exists', 'Já existe um usuário com esse e-mail.') : fail(400, 'create_failed', created.error || 'Não foi possível criar o usuário.');
    }
    const err = await d.updateProfile(created.id, { name, role, active: true, permissions: role === 'admin' ? {} : cleanPermissions(b.permissions) });
    if (err) {
      await d.deleteUser(created.id);   // desfaz: não deixa um login sem perfil
      return fail(500, 'profile_failed', 'O usuário não foi criado porque o banco ainda não tem a tabela de perfis. Rode o schema.sql no SQL Editor do Supabase. (' + err + ')');
    }
    return { status: 200, body: { ok: true, id: created.id } };
  }

  if (action === 'set_password') {
    const userId = String(b.userId || '');
    const password = String(b.password || '');
    if (!userId) return fail(400, 'bad_request', 'Usuário não informado.');
    if (password.length < 8) return fail(400, 'weak_password', 'A senha precisa ter pelo menos 8 caracteres.');
    const err = await d.setPassword(userId, password);
    return err ? fail(400, 'password_failed', err) : { status: 200, body: { ok: true } };
  }

  if (action === 'delete') {
    const userId = String(b.userId || '');
    if (!userId) return fail(400, 'bad_request', 'Usuário não informado.');
    if (userId === caller.id) return fail(400, 'cannot_delete_self', 'Você não pode excluir o seu próprio usuário.');
    const target = await d.getProfile(userId);
    if (target && target.active && target.role === 'admin' && (await d.countOtherActiveAdmins(userId)) === 0) {
      return fail(409, 'last_admin', 'Não é possível excluir o último administrador ativo.');
    }
    const err = await d.deleteUser(userId);
    return err ? fail(400, 'delete_failed', err) : { status: 200, body: { ok: true } };
  }

  return fail(400, 'bad_request', 'Ação desconhecida.');
}

// ---------- ligação com o Supabase (só roda dentro do Deno) ----------
const D = (globalThis as any).Deno;
if (D && D.serve) {
  const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2');
  const sb = createClient(D.env.get('SUPABASE_URL')!, (D.env.get('SERVICE_ROLE_KEY') || D.env.get('SUPABASE_SERVICE_ROLE_KEY'))!, { auth: { persistSession: false, autoRefreshToken: false } });
  const deps: Deps = {
    async getCaller(token) { const { data, error } = await sb.auth.getUser(token); return error || !data.user ? null : { id: data.user.id }; },
    async getProfile(id) { const { data } = await sb.from('app_users').select('role,active').eq('id', id).maybeSingle(); return data || null; },
    async countOtherActiveAdmins(exceptId) { const { count } = await sb.from('app_users').select('id', { count: 'exact', head: true }).eq('role', 'admin').eq('active', true).neq('id', exceptId); return count || 0; },
    async createUser(a) { const { data, error } = await sb.auth.admin.createUser({ email: a.email, password: a.password, email_confirm: true, user_metadata: { name: a.name } }); return error ? { error: error.message } : { id: data.user.id }; },
    async updateProfile(id, patch) { const { error } = await sb.from('app_users').update(patch).eq('id', id); return error ? error.message : null; },
    async setPassword(id, password) { const { error } = await sb.auth.admin.updateUserById(id, { password }); return error ? error.message : null; },
    async deleteUser(id) { const { error } = await sb.auth.admin.deleteUser(id); return error ? error.message : null; },
  };
  const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
  D.serve(async (req: Request) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
    let body: unknown = {}; try { body = await req.json(); } catch (_e) { /* corpo vazio */ }
    const headers: Record<string, string> = {}; req.headers.forEach((v, k) => { headers[k] = v; });
    const r = await handle({ method: req.method, headers, body }, deps);
    return new Response(JSON.stringify(r.body), { status: r.status, headers: { ...cors, 'Content-Type': 'application/json' } });
  });
}
