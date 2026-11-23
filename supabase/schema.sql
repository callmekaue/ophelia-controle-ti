-- ============================================================
-- SISTEMA DE CONTROLE DE TI — banco de dados (Supabase / PostgreSQL)
--
-- Como usar:
--   1. Supabase -> seu projeto -> "SQL Editor" -> "New query"
--   2. Cole TODO este arquivo e clique em "Run"
--   3. Deve aparecer "Success. No rows returned" (sem faixa vermelha)
--
-- É seguro rodar de novo: tudo usa "if not exists" / "on conflict".
--
-- SEGURANÇA: o sistema não tem tela de login (uso interno, igual ao Gestor
-- de Turmas). As policies abaixo liberam leitura e escrita para a chave
-- anon/publishable. Quem tiver a URL + a chave consegue ler e alterar os
-- dados e os PDFs. Não publique essas credenciais. Para exigir login no
-- futuro, troque "to anon, authenticated" por "to authenticated".
-- ============================================================

create table if not exists categories (
  id   text primary key,
  name text not null unique
);

create table if not exists locations (
  id          text primary key,
  name        text not null unique,
  description text default ''
);

-- setores: cada setor pertence a um local (galpão); o mesmo nome pode existir em locais diferentes
create table if not exists sectors (
  id          text primary key,
  location_id text references locations(id) on delete restrict,
  name        text not null,
  description text default ''
);

create table if not exists responsibles (
  id           text primary key,
  name         text not null,
  registration text default '',
  department   text default '',
  email        text default '',
  phone        text default ''
);

create table if not exists products (
  id          text primary key,
  category_id text not null references categories(id) on delete restrict,
  name        text not null,
  brand       text default '',
  model       text default '',
  subtype     text default ''
);
alter table products add column if not exists asset_value numeric(14,2) not null default 0;

create table if not exists equipments (
  id             text primary key,
  product_id     text not null references products(id) on delete restrict,
  patrimony      text not null,
  serial         text default '',
  status         text not null default 'Em estoque'
                 check (status in ('Em uso','Em estoque','Em manutenção','Emprestado','Baixado')),
  location_id    text references locations(id) on delete set null,
  sector_id      text references sectors(id) on delete set null,
  responsible_id text references responsibles(id) on delete set null,
  acquired_at    date,
  notes          text default '',
  created_at_ms  bigint,
  updated_at     timestamptz not null default now()
);

create table if not exists movements (
  id                  text primary key,
  equipment_id        text not null references equipments(id) on delete cascade,
  type                text not null,
  from_location_id    text,
  to_location_id      text,
  from_responsible_id text,
  to_responsible_id   text,
  from_status         text,
  to_status           text,
  description         text default '',
  created_at_ms       bigint
);

create table if not exists terms (
  id               text primary key,
  number           text not null unique,
  equipment_id     text references equipments(id) on delete set null,
  responsible_id   text references responsibles(id) on delete set null,
  equipment_label  text default '',
  patrimony        text default '',
  serial           text default '',
  responsible_name text default '',
  location_name    text default '',
  org_name         text default '',
  file_path        text default '',
  file_url         text default '',
  kind             text not null default 'entrega',
  notes            text default '',
  signed_file_path text default '',
  signed_file_url  text default '',
  signed_file_name text default '',
  signed_at_ms     bigint,
  created_at_ms    bigint
);

-- bancos criados com versões anteriores deste script: adiciona o que faltar
-- (tipo do termo: entrega/devolução, e o arquivo assinado anexado)
alter table terms add column if not exists kind text not null default 'entrega';
alter table terms add column if not exists notes text default '';
alter table terms add column if not exists signed_file_path text default '';
alter table terms add column if not exists signed_file_url text default '';
alter table terms add column if not exists signed_file_name text default '';
alter table terms add column if not exists signed_at_ms bigint;
alter table terms drop constraint if exists terms_kind_check;
alter table terms add constraint terms_kind_check check (kind in ('entrega','devolucao'));

-- anexos assinados: cada arquivo salvo é guardado (backup); o mais recente é o "atual" do termo
create table if not exists term_attachments (
  id            text primary key,
  term_id       text not null references terms(id) on delete cascade,
  file_path     text not null,
  file_url      text default '',
  file_name     text default '',
  size_bytes    bigint default 0,
  created_at_ms bigint
);

create table if not exists settings (
  id       text primary key default 'singleton',
  org_name text default '',
  city     text default ''
);

-- índices e unicidade (patrimônio e série não repetem, ignorando maiúsculas)
create unique index if not exists uq_equipments_patrimony on equipments (lower(patrimony));
create unique index if not exists uq_equipments_serial on equipments (lower(serial)) where serial <> '';
create index if not exists idx_products_category      on products(category_id);
create index if not exists idx_equipments_product     on equipments(product_id);
create index if not exists idx_equipments_location    on equipments(location_id);
-- bancos criados antes dos setores: acrescenta a coluna (não faz nada se já existir)
alter table equipments add column if not exists sector_id text references sectors(id) on delete set null;
create index if not exists idx_equipments_sector      on equipments(sector_id);
-- bancos que já tinham a tabela de setores da versão anterior (sem local e com nome único)
alter table sectors add column if not exists location_id text references locations(id) on delete restrict;
alter table sectors drop constraint if exists sectors_name_key;
create unique index if not exists uq_sectors_location_name on sectors(location_id, name);
create index if not exists idx_sectors_location on sectors(location_id);
create index if not exists idx_equipments_responsible on equipments(responsible_id);
create index if not exists idx_equipments_status      on equipments(status);
create index if not exists idx_movements_equipment    on movements(equipment_id);
create index if not exists idx_movements_created      on movements(created_at_ms desc);
create index if not exists idx_attachments_term on term_attachments(term_id);
create index if not exists idx_terms_equipment        on terms(equipment_id);

-- trigger: mantém equipments.updated_at atualizado
create or replace function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_equipments_updated_at on equipments;
create trigger trg_equipments_updated_at before update on equipments
  for each row execute function set_updated_at();

-- ============================================================
-- INFORMAÇÕES ADMINISTRATIVAS DE TI (galpões, internet, Wi-Fi, dispositivos de rede)
-- ============================================================
create table if not exists sites (
  id            text primary key,
  name          text not null unique,
  site_type     text not null default 'filial' check (site_type in ('matriz','filial')),
  legal_name    text default '',
  trade_name    text default '',
  cnpj          text default '',
  state_reg     text default '',
  opened_at     date,
  phone         text default '',
  email         text default '',
  manager       text default '',
  status        text not null default 'ativo' check (status in ('ativo','inativo')),
  cep           text default '',
  uf            text default '',
  city          text default '',
  district      text default '',
  street        text default '',
  number        text default '',
  complement    text default '',
  reference     text default '',
  notes         text default '',
  updated_at_ms bigint,
  updated_by    text default '',
  created_at_ms bigint
);

create table if not exists internet_links (
  id               text primary key,
  site_id          text not null references sites(id) on delete cascade,
  name             text not null,
  provider         text default '',
  link_type        text not null default 'fibra' check (link_type in ('fibra','radio','outro')),
  plan             text default '',
  contract_number  text default '',
  circuit_id       text default '',
  install_address  text default '',
  public_ip        text default '',
  ip_mode          text not null default 'dinamico' check (ip_mode in ('fixo','dinamico')),
  equipment        text default '',
  equipment_model  text default '',
  equipment_serial text default '',
  installed_at     date,
  renewal_at       date,
  support_phone    text default '',
  notes            text default '',
  status           text not null default 'ativa' check (status in ('ativa','inativa','manutencao')),
  updated_at_ms    bigint,
  updated_by       text default '',
  created_at_ms    bigint
);

-- password_enc guarda a senha CRIPTOGRAFADA no navegador (AES-256-GCM); o banco nunca vê a senha em texto
create table if not exists wifi_networks (
  id                 text primary key,
  site_id            text not null references sites(id) on delete cascade,
  ssid               text not null,
  password_enc       text default '',
  usage_type         text not null default 'corporativa' check (usage_type in ('corporativa','visitantes','dispositivos','personalizada')),
  usage_custom       text default '',
  equipment          text default '',
  equipment_location text default '',
  frequency          text default '',
  notes              text default '',
  status             text not null default 'ativa' check (status in ('ativa','inativa')),
  updated_at_ms      bigint,
  updated_by         text default '',
  created_at_ms      bigint
);

create table if not exists network_devices (
  id            text primary key,
  site_id       text not null references sites(id) on delete cascade,
  name          text not null,
  device_type   text not null default 'access_point' check (device_type in ('repetidor','access_point','roteador','outro')),
  brand         text default '',
  model         text default '',
  serial        text default '',
  location      text default '',
  wifi_id       text references wifi_networks(id) on delete set null,
  ssid          text default '',
  password_enc  text default '',
  mgmt_ip       text default '',
  notes         text default '',
  status        text not null default 'ativo' check (status in ('ativo','inativo','manutencao')),
  updated_at_ms bigint,
  updated_by    text default '',
  created_at_ms bigint
);

-- cofre de senhas: guarda só o "sal" e uma verificação criptografada; a senha mestra nunca é salva
create table if not exists vault (
  id            text primary key default 'singleton',
  salt          text not null,
  verifier      text not null,
  updated_at_ms bigint
);

create index if not exists idx_internet_links_site on internet_links(site_id);
create index if not exists idx_wifi_networks_site  on wifi_networks(site_id);
create index if not exists idx_network_devices_site on network_devices(site_id);
create index if not exists idx_network_devices_wifi on network_devices(wifi_id);

-- ============================================================
-- ACEITE DIGITAL DE TERMOS
-- O painel só CRIA a solicitação. Enviar o e-mail, gerar o link e marcar "aceito" é feito
-- exclusivamente pela Edge Function term-acceptance (chave de serviço, que nunca sai do servidor).
-- Por isso esta tabela NÃO tem política de UPDATE/DELETE para a chave pública: ninguém que tenha só
-- a chave anon consegue marcar um termo como aceito. (Apagar o termo apaga o aceite, em cascata.)
-- ============================================================
create table if not exists term_acceptances (
  id               text primary key,
  term_id          text not null references terms(id) on delete cascade,
  recipient_name   text default '',
  recipient_email  text default '',
  status           text not null default 'pendente' check (status in ('pendente','aceito','expirado','cancelado')),
  token_hash       text unique,               -- só o hash SHA-256 do token do link (o token vai apenas no e-mail)
  delivery         text not null default 'email' check (delivery in ('email','manual')),
  sent_at_ms       bigint,
  last_sent_at_ms  bigint,
  send_count       int not null default 0,
  expires_at_ms    bigint,
  doc_sha256       text default '',           -- hash do PDF original no momento da solicitação
  accepted_at_ms   bigint,
  accepted_name    text default '',
  accepted_ip      text default '',
  accepted_ua      text default '',
  verification_code text default '',
  created_at_ms    bigint,
  created_by       text default ''
);
create index if not exists idx_term_acceptances_term on term_acceptances(term_id);

alter table term_acceptances enable row level security;
drop policy if exists "acceptances select" on term_acceptances;
drop policy if exists "acceptances insert" on term_acceptances;
drop policy if exists "allow anon all" on term_acceptances;

-- ============================================================
-- ACESSO POR LOGIN (Supabase Auth) E PERMISSÕES POR MÓDULO
-- Só entra quem está logado e ativo. Cada usuário tem um perfil (administrador ou
-- usuário) e, por módulo, um nível: none (sem acesso), view (só ver) ou edit (ver e editar).
-- Módulos: dashboard, equipments, movements, terms, registry, infra, planning.
-- ============================================================
create table if not exists app_users (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null default '',
  name        text not null default '',
  role        text not null default 'user' check (role in ('admin','user')),
  active      boolean not null default true,
  permissions jsonb not null default '{}'::jsonb,
  created_at  timestamptz default now()
);
create unique index if not exists uq_app_users_email on app_users(lower(email)) where email <> '';

-- nível do usuário logado num módulo: 0 sem acesso, 1 só ver, 2 editar (administrador ativo = 2 em tudo)
create or replace function app_level(p_mod text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when u.role = 'admin' then 2
      else case coalesce(u.permissions ->> p_mod, 'none') when 'edit' then 2 when 'view' then 1 else 0 end
    end
    from app_users u where u.id = auth.uid() and u.active
  ), 0)
$$;
create or replace function app_can(p_mods text[], p_min int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from unnest(p_mods) m where app_level(m) >= p_min)
$$;
create or replace function app_any_access() returns boolean
language sql stable security definer set search_path = public as $$
  select app_can(array['dashboard','equipments','movements','terms','registry','infra','planning'], 1)
$$;
-- acesso ao inventário (equipamentos, cadastros, termos...): qualquer módulo MENOS Informações de TI
create or replace function app_inv_access() returns boolean
language sql stable security definer set search_path = public as $$
  select app_can(array['dashboard','equipments','movements','terms','registry'], 1)
$$;
create or replace function app_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_users where id = auth.uid() and active and role = 'admin')
$$;
revoke all on function app_level(text), app_can(text[], int), app_any_access(), app_inv_access(), app_is_admin() from public, anon;
grant execute on function app_level(text), app_can(text[], int), app_any_access(), app_inv_access(), app_is_admin() to authenticated, service_role;

-- todo usuário criado no Authentication ganha um perfil sem acesso; o administrador libera depois
create or replace function app_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into app_users (id, email, name)
  values (new.id, coalesce(new.email, ''), coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(coalesce(new.email, ''), '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists app_on_auth_user_created on auth.users;
create trigger app_on_auth_user_created after insert on auth.users
  for each row execute function app_handle_new_user();
-- quem já existia no Authentication também ganha perfil
insert into app_users (id, email, name)
select id, coalesce(email, ''), split_part(coalesce(email, ''), '@', 1) from auth.users
on conflict (id) do nothing;

-- nunca deixa o sistema sem administrador ativo
create or replace function app_users_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'admin' and old.active
     and (tg_op = 'DELETE' or new.role <> 'admin' or not new.active)
     and not exists (select 1 from app_users where role = 'admin' and active and id <> old.id) then
    raise exception 'Não é possível remover, desativar ou rebaixar o último administrador ativo.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists app_users_guard_trg on app_users;
create trigger app_users_guard_trg before update or delete on app_users
  for each row execute function app_users_guard();

-- torna alguém administrador (rode no SQL Editor, depois de criar o usuário em Authentication > Users):
--   select promote_admin('seu@email.com', 'Kauê');
create or replace function promote_admin(p_email text, p_name text default null) returns text
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update app_users set role = 'admin', active = true, name = coalesce(nullif(p_name, ''), name)
   where lower(email) = lower(p_email);
  get diagnostics n = row_count;
  if n = 0 then return 'Nenhum usuário com esse e-mail. Crie primeiro em Authentication > Users > Add user.'; end if;
  return 'OK: ' || p_email || ' agora é administrador.';
end $$;
revoke all on function promote_admin(text, text) from public, anon, authenticated;

-- ---------- Planejamento em T.I. (quadro de demandas) ----------
create table if not exists demands (
  id            text primary key,
  title         text not null,
  description   text default '',
  level         text not null default 'nao_urgente',   -- nao_urgente | urgente | muito_urgente | concluido
  position      double precision not null default 0,
  due_date      text default '',
  updated_at_ms bigint,
  updated_by    text default '',
  created_at_ms bigint,
  created_by    text default '',
  completed_at_ms bigint
);
alter table demands add column if not exists created_by text default '';
alter table demands add column if not exists completed_at_ms bigint;

-- Tarefas mensais: "checks" guarda um JSON {"2026-11": {"at": ms, "by": "nome"}} — o mês muda sozinho, então os checks "zeram" todo dia 1º
create table if not exists monthly_tasks (
  id            text primary key,
  title         text not null,
  description   text default '',
  position      double precision not null default 0,
  checks        text not null default '{}',
  created_by    text default '',
  created_at_ms bigint,
  updated_at_ms bigint,
  updated_by    text default ''
);

-- ---------- políticas (RLS): nada fica aberto para quem não está logado ----------
alter table app_users enable row level security;
drop policy if exists "allow anon all" on app_users;
drop policy if exists "app_users read" on app_users;
drop policy if exists "app_users update" on app_users;
create policy "app_users read"   on app_users for select to authenticated using (id = auth.uid() or app_is_admin());
create policy "app_users update" on app_users for update to authenticated using (app_is_admin()) with check (app_is_admin());

do $$
declare t text; r record;
begin
  -- apaga as políticas abertas da versão sem login e liga a RLS em tudo
  foreach t in array array['monthly_tasks','demands','categories','locations','sectors','responsibles','products','equipments','movements','terms','term_attachments','term_acceptances','settings','sites','internet_links','wifi_networks','network_devices','vault']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "allow anon all" on %I', t);
    execute format('drop policy if exists "app read" on %I', t);
    execute format('drop policy if exists "app write" on %I', t);
  end loop;

  -- leitura do inventário: usuário ativo com acesso a algum módulo (menos Informações de TI, que tem regra própria)
  foreach t in array array['categories','locations','sectors','responsibles','products','equipments','movements','terms','term_attachments','term_acceptances']
  loop
    execute format('create policy "app read" on %I for select to authenticated using (app_inv_access())', t);
  end loop;
  create policy "app read" on settings for select to authenticated using (app_any_access());
  foreach t in array array['sites','internet_links','wifi_networks','network_devices','vault']
  loop
    execute format('create policy "app read" on %I for select to authenticated using (app_can(array[''infra''], 1))', t);
  end loop;

  execute 'create policy "app read" on demands for select to authenticated using (app_can(array[''planning''], 1))';
  execute 'create policy "app read" on monthly_tasks for select to authenticated using (app_can(array[''planning''], 1))';

  -- escrita: precisa do nível "edit" no módulo dono da tabela
  for r in select * from (values
      ('categories','registry'), ('locations','registry'), ('sectors','registry'), ('responsibles','registry'), ('products','registry'),
      ('terms','terms'), ('term_attachments','terms'),
      ('sites','infra'), ('internet_links','infra'), ('wifi_networks','infra'), ('network_devices','infra'), ('vault','infra'), ('demands','planning'), ('monthly_tasks','planning')
    ) as v(tbl, modname)
  loop
    execute format('create policy "app write" on %I for all to authenticated using (app_can(array[%L], 2)) with check (app_can(array[%L], 2))', r.tbl, r.modname, r.modname);
  end loop;
end $$;

-- configurações da organização: Cadastros ou Termos
create policy "app write" on settings for all to authenticated
  using (app_can(array['registry','terms'], 2)) with check (app_can(array['registry','terms'], 2));
-- equipamentos: gravar (Equipamentos, Movimentações ou Termos, que registram devolução); excluir só quem edita Equipamentos
create policy "app write" on equipments for insert to authenticated with check (app_can(array['equipments','movements','terms'], 2));
drop policy if exists "app update" on equipments;
create policy "app update" on equipments for update to authenticated using (app_can(array['equipments','movements','terms'], 2)) with check (app_can(array['equipments','movements','terms'], 2));
drop policy if exists "app delete" on equipments;
create policy "app delete" on equipments for delete to authenticated using (app_can(array['equipments'], 2));
-- histórico de movimentações: só acrescenta (Equipamentos, Movimentações, Termos); apagar só quem edita Equipamentos
create policy "app write" on movements for insert to authenticated with check (app_can(array['equipments','movements','terms'], 2));
drop policy if exists "app delete" on movements;
create policy "app delete" on movements for delete to authenticated using (app_can(array['equipments'], 2));
-- aceite digital: o painel só cria a solicitação (o resto é feito pela função, no servidor)
create policy "app write" on term_acceptances for insert to authenticated
  with check (app_can(array['terms'], 2) and status = 'pendente' and token_hash is null and accepted_at_ms is null and send_count = 0);

-- Storage: bucket "termos" (PDFs). Qualquer pessoa com o link do arquivo consegue abrir (necessário no link de aceite);
-- enviar, trocar e apagar arquivos só quem edita Termos.
insert into storage.buckets (id, name, public) values ('termos', 'termos', true)
on conflict (id) do update set public = true;

drop policy if exists "termos select" on storage.objects;
drop policy if exists "termos insert" on storage.objects;
drop policy if exists "termos update" on storage.objects;
drop policy if exists "termos delete" on storage.objects;
create policy "termos select" on storage.objects for select to authenticated using (bucket_id = 'termos' and app_inv_access());
create policy "termos insert" on storage.objects for insert to authenticated with check (bucket_id = 'termos' and app_can(array['terms'], 2));
create policy "termos update" on storage.objects for update to authenticated using (bucket_id = 'termos' and app_can(array['terms'], 2)) with check (bucket_id = 'termos' and app_can(array['terms'], 2));
create policy "termos delete" on storage.objects for delete to authenticated using (bucket_id = 'termos' and app_can(array['terms'], 2));

-- dados iniciais (categorias padrão e linha de configuração)
insert into categories (id, name) values
  ('cat_notebook','Notebook'), ('cat_monitor','Monitor'), ('cat_impressora','Impressora'),
  ('cat_desktop','Desktop'), ('cat_celular','Celular'), ('cat_tablet','Tablet'),
  ('cat_periferico','Periférico'), ('cat_rede','Rede'), ('cat_outro','Outro')
on conflict (id) do nothing;

insert into settings (id) values ('singleton') on conflict (id) do nothing;

-- traz para a tabela de anexos os arquivos assinados anexados na versão anterior (uma única vez)
insert into term_attachments (id, term_id, file_path, file_url, file_name, size_bytes, created_at_ms)
select 'att_' || t.id, t.id, t.signed_file_path, coalesce(t.signed_file_url, ''), coalesce(t.signed_file_name, ''), 0, coalesce(t.signed_at_ms, t.created_at_ms)
from terms t
where coalesce(t.signed_file_path, '') <> ''
  and not exists (select 1 from term_attachments a where a.file_path = t.signed_file_path)
on conflict (id) do nothing;

-- galpões iniciais (só se a tabela estiver vazia; G1 a G4 — novos podem ser criados pelo sistema)
insert into sites (id, name, site_type, status, created_at_ms)
select v.id, v.name, 'filial', 'ativo', (extract(epoch from now()) * 1000)::bigint
from (values ('site_g1','G1'), ('site_g2','G2'), ('site_g3','G3'), ('site_g4','G4')) as v(id, name)
where not exists (select 1 from sites);

-- faz a API do Supabase enxergar tabelas/colunas novas na hora (sem esperar o cache)
notify pgrst, 'reload schema';
