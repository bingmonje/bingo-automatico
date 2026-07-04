-- Seguridad V1 para el frontend público.
-- Cierra exposición de PIN, agrega sesiones con token, rate limit y admin real.
-- Ejecutar una sola vez DESPUÉS de las migraciones funcionales existentes.

begin;

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.bingo_rate_limits (
  ambito text not null,
  clave text not null,
  ventana_inicio timestamptz not null default now(),
  intentos integer not null default 0,
  bloqueado_hasta timestamptz,
  primary key (ambito, clave)
);

create table if not exists public.bingo_sesiones_cliente (
  token_hash text primary key,
  usuario_id integer not null references public.usuarios_bingo(id) on delete cascade,
  creado_en timestamptz not null default now(),
  ultimo_uso timestamptz not null default now(),
  expira_en timestamptz not null
);

create index if not exists idx_bingo_sesiones_cliente_usuario
  on public.bingo_sesiones_cliente (usuario_id, expira_en);

create table if not exists public.bingo_admin_credenciales (
  id smallint primary key default 1 check (id = 1),
  usuario text not null unique,
  clave_hash text not null,
  activo boolean not null default true,
  actualizado_en timestamptz not null default now()
);

create table if not exists public.bingo_admin_sesiones (
  token_hash text primary key,
  creado_en timestamptz not null default now(),
  ultimo_uso timestamptz not null default now(),
  expira_en timestamptz not null
);

create table if not exists public.recuperaciones_pin_bingo (
  id bigserial primary key,
  usuario_id integer not null references public.usuarios_bingo(id) on delete cascade,
  telefono_verificado text not null,
  pin_hash_nuevo text not null,
  estado text not null default 'pendiente'
    check (estado in ('pendiente', 'aprobado', 'rechazado')),
  solicitado_en timestamptz not null default now(),
  resuelto_en timestamptz
);

create unique index if not exists idx_recuperaciones_pin_usuario_pendiente
  on public.recuperaciones_pin_bingo (usuario_id) where estado = 'pendiente';

alter table public.bingo_rate_limits enable row level security;
alter table public.bingo_sesiones_cliente enable row level security;
alter table public.bingo_admin_credenciales enable row level security;
alter table public.bingo_admin_sesiones enable row level security;
alter table public.recuperaciones_pin_bingo enable row level security;

revoke all on public.bingo_rate_limits from public, anon, authenticated;
revoke all on public.bingo_sesiones_cliente from public, anon, authenticated;
revoke all on public.bingo_admin_credenciales from public, anon, authenticated;
revoke all on public.bingo_admin_sesiones from public, anon, authenticated;
revoke all on public.recuperaciones_pin_bingo from public, anon, authenticated;

create or replace function public.bingo_origen_peticion()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_headers jsonb;
begin
  begin
    v_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  exception when others then
    v_headers := '{}'::jsonb;
  end;

  return left(coalesce(
    v_headers->>'cf-connecting-ip',
    split_part(v_headers->>'x-forwarded-for', ',', 1),
    v_headers->>'x-real-ip',
    v_headers->>'user-agent',
    'origen-desconocido'
  ), 200);
end;
$$;

create or replace function public.bingo_consumir_rate_limit(
  p_ambito text,
  p_clave text,
  p_max_intentos integer,
  p_ventana_segundos integer,
  p_bloqueo_segundos integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fila public.bingo_rate_limits%rowtype;
  v_ahora timestamptz := clock_timestamp();
  v_clave text := encode(extensions.digest(coalesce(p_clave, ''), 'sha256'), 'hex');
begin
  if p_max_intentos < 1 or p_ventana_segundos < 1 or p_bloqueo_segundos < 1 then
    raise exception 'Configuracion de rate limit invalida';
  end if;

  insert into public.bingo_rate_limits (ambito, clave, ventana_inicio, intentos)
  values (left(p_ambito, 60), v_clave, v_ahora, 0)
  on conflict (ambito, clave) do nothing;

  select * into v_fila
    from public.bingo_rate_limits
   where ambito = left(p_ambito, 60) and clave = v_clave
   for update;

  if v_fila.bloqueado_hasta is not null and v_fila.bloqueado_hasta > v_ahora then
    return jsonb_build_object(
      'permitido', false,
      'reintentar_en', greatest(1, ceil(extract(epoch from (v_fila.bloqueado_hasta - v_ahora)))::integer)
    );
  end if;

  if v_fila.ventana_inicio + make_interval(secs => p_ventana_segundos) <= v_ahora then
    update public.bingo_rate_limits
       set ventana_inicio = v_ahora, intentos = 1, bloqueado_hasta = null
     where ambito = left(p_ambito, 60) and clave = v_clave;
    return jsonb_build_object('permitido', true, 'restantes', p_max_intentos - 1);
  end if;

  if v_fila.intentos + 1 > p_max_intentos then
    update public.bingo_rate_limits
       set intentos = intentos + 1,
           bloqueado_hasta = v_ahora + make_interval(secs => p_bloqueo_segundos)
     where ambito = left(p_ambito, 60) and clave = v_clave;
    return jsonb_build_object('permitido', false, 'reintentar_en', p_bloqueo_segundos);
  end if;

  update public.bingo_rate_limits
     set intentos = intentos + 1, bloqueado_hasta = null
   where ambito = left(p_ambito, 60) and clave = v_clave;

  return jsonb_build_object('permitido', true, 'restantes', p_max_intentos - v_fila.intentos - 1);
end;
$$;

create or replace function public.bingo_registrar_usuario(
  p_cedula text,
  p_nombre text,
  p_telefono text,
  p_email text,
  p_pin_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario public.usuarios_bingo%rowtype;
  v_limite jsonb;
begin
  v_limite := public.bingo_consumir_rate_limit(
    'registro_cliente',
    public.bingo_origen_peticion() || '|' || regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g'),
    3, 3600, 3600
  );

  if not coalesce((v_limite->>'permitido')::boolean, false) then
    return jsonb_build_object('ok', false, 'codigo', 'rate_limit', 'reintentar_en', v_limite->'reintentar_en');
  end if;

  if length(trim(coalesce(p_nombre, ''))) < 2
     or length(regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g')) < 6
     or length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) < 10
     or coalesce(p_pin_hash, '') !~ '^[0-9]{4,12}$' then
    return jsonb_build_object('ok', false, 'codigo', 'datos_invalidos');
  end if;

  insert into public.usuarios_bingo (cedula, nombre, telefono, email, pin_hash)
  values (
    upper(regexp_replace(trim(p_cedula), '\s+', '', 'g')),
    left(trim(p_nombre), 100),
    left(regexp_replace(p_telefono, '\D', '', 'g'), 15),
    '',
    extensions.crypt(p_pin_hash, extensions.gen_salt('bf', 11))
  )
  on conflict (cedula) do nothing
  returning * into v_usuario;

  if not found then return jsonb_build_object('ok', false, 'codigo', 'cedula_registrada'); end if;

  insert into public.billeteras_bingo (usuario_id, saldo)
  values (v_usuario.id, 0) on conflict (usuario_id) do nothing;

  return jsonb_build_object('ok', true, 'usuario', jsonb_build_object(
    'id', v_usuario.id, 'cedula', v_usuario.cedula,
    'nombre', v_usuario.nombre, 'telefono', v_usuario.telefono
  ));
end;
$$;

create or replace function public.bingo_solicitar_recuperacion_pin(
  p_cedula text,
  p_telefono text,
  p_pin_hash_nuevo text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario_id integer;
  v_solicitud_id bigint;
  v_cedula text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_telefono text := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
  v_limite jsonb;
begin
  v_limite := public.bingo_consumir_rate_limit('recuperar_pin', public.bingo_origen_peticion() || '|' || v_cedula || '|' || right(v_telefono, 10), 3, 3600, 3600);
  if not coalesce((v_limite->>'permitido')::boolean, false) then
    return jsonb_build_object('ok', false, 'codigo', 'rate_limit', 'reintentar_en', v_limite->'reintentar_en');
  end if;

  if length(v_cedula) < 6 or length(v_telefono) < 10 or coalesce(p_pin_hash_nuevo, '') !~ '^[0-9]{4,12}$' then
    return jsonb_build_object('ok', false, 'codigo', 'datos_invalidos');
  end if;

  select id into v_usuario_id from public.usuarios_bingo
   where activo = true
     and regexp_replace(coalesce(cedula, ''), '\D', '', 'g') = v_cedula
     and right(regexp_replace(coalesce(telefono, ''), '\D', '', 'g'), 10) = right(v_telefono, 10)
   limit 1;

  if not found then return jsonb_build_object('ok', false, 'codigo', 'datos_no_coinciden'); end if;

  perform pg_advisory_xact_lock(75002, 8);
  update public.recuperaciones_pin_bingo
     set telefono_verificado = v_telefono,
         pin_hash_nuevo = extensions.crypt(p_pin_hash_nuevo, extensions.gen_salt('bf', 11)),
         solicitado_en = now()
   where usuario_id = v_usuario_id and estado = 'pendiente'
  returning id into v_solicitud_id;

  if not found then
    insert into public.recuperaciones_pin_bingo (usuario_id, telefono_verificado, pin_hash_nuevo)
    values (v_usuario_id, v_telefono, extensions.crypt(p_pin_hash_nuevo, extensions.gen_salt('bf', 11)))
    returning id into v_solicitud_id;
  end if;

  return jsonb_build_object('ok', true, 'solicitud_id', v_solicitud_id, 'estado', 'pendiente');
end;
$$;

create or replace function public.bingo_crear_token()
returns text
language sql
volatile
security definer
set search_path = ''
as $$
  select encode(extensions.gen_random_bytes(32), 'hex');
$$;

create or replace function public.bingo_token_hash(p_token text)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

create or replace function public.bingo_usuario_por_token(p_token text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario_id integer;
begin
  select usuario_id into v_usuario_id
    from public.bingo_sesiones_cliente
   where token_hash = public.bingo_token_hash(p_token)
     and expira_en > now()
   for update;

  if not found then return null; end if;

  update public.bingo_sesiones_cliente
     set ultimo_uso = now(), expira_en = greatest(expira_en, now() + interval '2 hours')
   where token_hash = public.bingo_token_hash(p_token);

  return v_usuario_id;
end;
$$;

create or replace function public.bingo_login_cliente_seguro(
  p_cedula text,
  p_pin text,
  p_pin_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario public.usuarios_bingo%rowtype;
  v_limite jsonb;
  v_token text;
  v_valido boolean := false;
begin
  v_limite := public.bingo_consumir_rate_limit(
    'login_cliente',
    public.bingo_origen_peticion() || '|' || regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g'),
    5, 900, 1800
  );

  if not coalesce((v_limite->>'permitido')::boolean, false) then
    return jsonb_build_object('ok', false, 'codigo', 'rate_limit', 'reintentar_en', v_limite->'reintentar_en');
  end if;

  if length(coalesce(p_pin, '')) < 4 or length(coalesce(p_pin, '')) > 64 then
    return jsonb_build_object('ok', false, 'codigo', 'credenciales_invalidas');
  end if;

  select * into v_usuario
    from public.usuarios_bingo
   where regexp_replace(coalesce(cedula, ''), '\D', '', 'g')
       = regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g')
     and activo = true
   limit 1;

  if found then
    if v_usuario.pin_hash like '$2%' then
      v_valido := extensions.crypt(p_pin, v_usuario.pin_hash) = v_usuario.pin_hash;
    else
      v_valido := v_usuario.pin_hash = p_pin_sha256 or v_usuario.pin_hash = p_pin;
    end if;
  end if;

  if not v_valido then
    return jsonb_build_object('ok', false, 'codigo', 'credenciales_invalidas');
  end if;

  if v_usuario.pin_hash not like '$2%' then
    update public.usuarios_bingo
       set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 11))
     where id = v_usuario.id;
  end if;

  delete from public.bingo_sesiones_cliente
   where usuario_id = v_usuario.id or expira_en <= now();

  v_token := public.bingo_crear_token();
  insert into public.bingo_sesiones_cliente (token_hash, usuario_id, expira_en)
  values (public.bingo_token_hash(v_token), v_usuario.id, now() + interval '12 hours');

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'usuario', jsonb_build_object(
      'id', v_usuario.id,
      'nombre', v_usuario.nombre,
      'cedula', v_usuario.cedula,
      'telefono', v_usuario.telefono
    )
  );
end;
$$;

create or replace function public.bingo_validar_sesion_cliente(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario public.usuarios_bingo%rowtype;
  v_id integer;
begin
  v_id := public.bingo_usuario_por_token(p_token);
  if v_id is null then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;
  select * into v_usuario from public.usuarios_bingo where id = v_id and activo = true;
  if not found then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;
  return jsonb_build_object('ok', true, 'usuario', jsonb_build_object(
    'id', v_usuario.id, 'nombre', v_usuario.nombre,
    'cedula', v_usuario.cedula, 'telefono', v_usuario.telefono
  ));
end;
$$;

create or replace function public.bingo_cerrar_sesion_cliente(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.bingo_sesiones_cliente where token_hash = public.bingo_token_hash(p_token);
  return jsonb_build_object('ok', true);
end;
$$;

-- Toda operacion privada del cliente obtiene el usuario desde el token.
-- El navegador nunca decide que usuario ni que precio se aplica.
create or replace function public.bingo_cliente_cuenta_segura(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario_id integer;
  v_saldo numeric;
  v_recarga jsonb;
  v_retiro jsonb;
  v_datos_retiro jsonb;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then
    return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida');
  end if;

  select coalesce(saldo, 0) into v_saldo
    from public.billeteras_bingo where usuario_id = v_usuario_id;

  select jsonb_build_object(
           'id', r.id, 'monto', r.monto, 'estado', r.estado,
           'solicitado_en', r.solicitado_en, 'procesado_en', r.procesado_en
         ) into v_recarga
    from public.recargas_bingo r
   where r.usuario_id = v_usuario_id
   order by r.solicitado_en desc limit 1;

  select jsonb_build_object(
           'id', r.id, 'monto', r.monto, 'estado', r.estado,
           'solicitado_en', r.solicitado_en, 'procesado_en', r.procesado_en
         ) into v_retiro
    from public.retiros_bingo r
   where r.usuario_id = v_usuario_id
   order by r.solicitado_en desc limit 1;

  select jsonb_build_object(
           'telefono', r.telefono, 'cedula_titular', r.cedula_titular, 'banco', r.banco
         ) into v_datos_retiro
    from public.retiros_bingo r
   where r.usuario_id = v_usuario_id
   order by r.solicitado_en desc limit 1;

  return jsonb_build_object(
    'ok', true, 'saldo', coalesce(v_saldo, 0),
    'ultima_recarga', v_recarga, 'ultimo_retiro', v_retiro,
    'datos_retiro', v_datos_retiro
  );
end;
$$;

create or replace function public.bingo_cliente_movimientos_seguro(p_token text)
returns table (
  id bigint, tipo text, monto numeric, saldo_anterior numeric,
  saldo_nuevo numeric, descripcion text, referencia text, creado_en timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare v_usuario_id integer;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then
    raise exception 'Sesion de cliente invalida' using errcode = '42501';
  end if;
  return query
    select m.id::bigint, m.tipo::text, m.monto::numeric,
           m.saldo_anterior::numeric, m.saldo_nuevo::numeric,
           m.descripcion::text, m.referencia::text, m.creado_en::timestamptz
      from public.billetera_movimientos m
     where m.usuario_id = v_usuario_id
     order by m.creado_en desc limit 100;
end;
$$;

create or replace function public.bingo_cliente_solicitar_recarga_seguro(
  p_token text, p_monto numeric, p_referencia text, p_comprobante_url text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_usuario_id integer; v_id bigint; v_limite jsonb;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;
  v_limite := public.bingo_consumir_rate_limit('solicitar_recarga', v_usuario_id::text, 6, 3600, 3600);
  if not coalesce((v_limite->>'permitido')::boolean, false) then
    return jsonb_build_object('ok', false, 'codigo', 'rate_limit', 'reintentar_en', v_limite->'reintentar_en');
  end if;
  if coalesce(p_monto, 0) <= 0 or p_monto > 100000000
     or coalesce(p_referencia, '') !~ '^[0-9]{4}$'
     or length(coalesce(p_comprobante_url, '')) < 20
     or length(p_comprobante_url) > 1000 then
    return jsonb_build_object('ok', false, 'codigo', 'datos_invalidos');
  end if;
  insert into public.recargas_bingo
    (usuario_id, monto, referencia_pago, comprobante_url, estado)
  values (v_usuario_id, round(p_monto, 2), p_referencia, p_comprobante_url, 'pendiente')
  returning id::bigint into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.bingo_cliente_solicitar_retiro_seguro(
  p_token text, p_monto numeric, p_telefono text, p_cedula_titular text, p_banco text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_usuario_id integer; v_id bigint; v_saldo numeric; v_limite jsonb;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;
  v_limite := public.bingo_consumir_rate_limit('solicitar_retiro', v_usuario_id::text, 4, 3600, 3600);
  if not coalesce((v_limite->>'permitido')::boolean, false) then
    return jsonb_build_object('ok', false, 'codigo', 'rate_limit', 'reintentar_en', v_limite->'reintentar_en');
  end if;
  if coalesce(p_monto, 0) <= 0 or p_monto > 100000000
     or length(regexp_replace(coalesce(p_telefono, ''), '[^0-9|A-Z]', '', 'g')) < 10
     or length(regexp_replace(coalesce(p_cedula_titular, ''), '\D', '', 'g')) < 6
     or length(trim(coalesce(p_banco, ''))) < 2 then
    return jsonb_build_object('ok', false, 'codigo', 'datos_invalidos');
  end if;
  if exists (select 1 from public.retiros_bingo where usuario_id = v_usuario_id and estado = 'pendiente') then
    return jsonb_build_object('ok', false, 'codigo', 'retiro_pendiente');
  end if;
  select coalesce(saldo, 0) into v_saldo from public.billeteras_bingo
   where usuario_id = v_usuario_id for update;
  if coalesce(v_saldo, 0) < p_monto then
    return jsonb_build_object('ok', false, 'codigo', 'saldo_insuficiente', 'saldo', coalesce(v_saldo, 0));
  end if;
  insert into public.retiros_bingo
    (usuario_id, monto, telefono, cedula_titular, banco, estado)
  values (
    v_usuario_id, round(p_monto, 2), left(p_telefono, 40),
    left(regexp_replace(p_cedula_titular, '\D', '', 'g'), 12),
    left(trim(p_banco), 100), 'pendiente'
  ) returning id::bigint into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'saldo', v_saldo);
end;
$$;

create or replace function public.bingo_reservar_cartones_seguro(
  p_token text, p_cartones integer[], p_promocion_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario public.usuarios_bingo%rowtype;
  v_usuario_id integer;
  v_cantidad integer;
  v_precio_total numeric;
  v_precio_unitario numeric;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;
  select * into v_usuario from public.usuarios_bingo where id = v_usuario_id and activo = true;
  if not found then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;

  select count(*) into v_cantidad from (select distinct x from unnest(coalesce(p_cartones, '{}'::integer[])) x) s;
  if v_cantidad < 1 or v_cantidad > 100 or v_cantidad <> coalesce(array_length(p_cartones, 1), 0) then
    return jsonb_build_object('ok', false, 'codigo', 'cartones_invalidos');
  end if;

  if p_promocion_id is not null then
    select precio into v_precio_total from public.promociones_cartones
     where id = p_promocion_id and activa = true and cantidad = v_cantidad;
    if not found then return jsonb_build_object('ok', false, 'codigo', 'promocion_invalida'); end if;
  else
    select case when valor ~ '^[0-9]+([.,][0-9]+)?$'
                then replace(valor, ',', '.')::numeric else null end
      into v_precio_unitario from public.configuracion where clave = 'precio_carton';
    if coalesce(v_precio_unitario, 0) <= 0 then
      return jsonb_build_object('ok', false, 'codigo', 'precio_no_configurado');
    end if;
    v_precio_total := round(v_precio_unitario * v_cantidad, 2);
  end if;

  return public.bingo_reservar_cartones(
    v_usuario.id, v_usuario.nombre, v_usuario.telefono, v_usuario.cedula,
    '', p_cartones, v_precio_total, p_promocion_id
  );
end;
$$;

create or replace function public.bingo_pagar_con_saldo_seguro(p_token text, p_apartado_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_usuario_id integer;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;
  return public.bingo_pagar_con_saldo(p_apartado_id, v_usuario_id);
end;
$$;

create or replace function public.bingo_liberar_reserva_seguro(p_token text, p_apartado_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_usuario_id integer;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida'); end if;
  if not exists (
    select 1 from public.apartados_temp a join public.usuarios_bingo u on u.id = v_usuario_id
     where a.id = p_apartado_id
       and regexp_replace(coalesce(a.cedula, ''), '\D', '', 'g') = regexp_replace(coalesce(u.cedula, ''), '\D', '', 'g')
  ) then return jsonb_build_object('ok', false, 'codigo', 'reserva_no_pertenece'); end if;
  return public.bingo_liberar_reserva(p_apartado_id);
end;
$$;

create or replace function public.bingo_configurar_admin_seguro(p_usuario text, p_clave text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(p_usuario, '') !~ '^[A-Za-z0-9_-]{4,40}$' or length(coalesce(p_clave, '')) < 14 then
    raise exception 'Usuario o clave de administrador no cumplen la seguridad minima';
  end if;

  insert into public.bingo_admin_credenciales (id, usuario, clave_hash, activo, actualizado_en)
  values (1, lower(p_usuario), extensions.crypt(p_clave, extensions.gen_salt('bf', 12)), true, now())
  on conflict (id) do update
    set usuario = excluded.usuario,
        clave_hash = excluded.clave_hash,
        activo = true,
        actualizado_en = now();

  delete from public.bingo_admin_sesiones;
end;
$$;

create or replace function public.bingo_admin_login_seguro(p_usuario text, p_clave text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.bingo_admin_credenciales%rowtype;
  v_limite jsonb;
  v_token text;
begin
  v_limite := public.bingo_consumir_rate_limit('login_admin', public.bingo_origen_peticion() || '|' || lower(coalesce(p_usuario, '')), 5, 900, 3600);
  if not coalesce((v_limite->>'permitido')::boolean, false) then
    return jsonb_build_object('ok', false, 'codigo', 'rate_limit', 'reintentar_en', v_limite->'reintentar_en');
  end if;

  select * into v_admin from public.bingo_admin_credenciales
   where id = 1 and usuario = lower(coalesce(p_usuario, '')) and activo = true;

  if not found or extensions.crypt(coalesce(p_clave, ''), v_admin.clave_hash) <> v_admin.clave_hash then
    return jsonb_build_object('ok', false, 'codigo', 'credenciales_invalidas');
  end if;

  delete from public.bingo_admin_sesiones where expira_en <= now();
  v_token := public.bingo_crear_token();
  insert into public.bingo_admin_sesiones (token_hash, expira_en)
  values (public.bingo_token_hash(v_token), now() + interval '8 hours');

  return jsonb_build_object('ok', true, 'token', v_token, 'expira_en', now() + interval '8 hours');
end;
$$;

create or replace function public.bingo_admin_requerir_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.bingo_admin_sesiones
     where token_hash = public.bingo_token_hash(p_token) and expira_en > now()
  ) then
    raise exception 'Sesion administrativa invalida' using errcode = '42501';
  end if;

  update public.bingo_admin_sesiones
     set ultimo_uso = now()
   where token_hash = public.bingo_token_hash(p_token);
end;
$$;

create or replace function public.bingo_admin_validar_sesion_seguro(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return jsonb_build_object('ok', true);
exception when insufficient_privilege then
  return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida');
end;
$$;

create or replace function public.bingo_admin_logout_seguro(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.bingo_admin_sesiones where token_hash = public.bingo_token_hash(p_token);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bingo_admin_listar_clientes_seguro(p_token text)
returns table (id integer, nombre text, cedula text, telefono text, saldo numeric)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return query
    select u.id::integer, u.nombre::text, u.cedula::text, u.telefono::text, coalesce(b.saldo, 0)
      from public.usuarios_bingo u
      left join public.billeteras_bingo b on b.usuario_id = u.id
     order by u.id;
end;
$$;

create or replace function public.bingo_admin_listar_recargas_seguro(p_token text)
returns table (id bigint, monto numeric, referencia_pago text, comprobante_url text, solicitado_en timestamptz, nombre text, cedula text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return query
    select r.id::bigint, r.monto, r.referencia_pago::text, r.comprobante_url::text,
           r.solicitado_en, u.nombre::text, u.cedula::text
      from public.recargas_bingo r join public.usuarios_bingo u on u.id = r.usuario_id
     where r.estado = 'pendiente' order by r.solicitado_en desc;
end;
$$;

create or replace function public.bingo_admin_listar_retiros_seguro(p_token text)
returns table (id bigint, monto numeric, telefono text, cedula_titular text, banco text, solicitado_en timestamptz, nombre text, cedula text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return query
    select r.id::bigint, r.monto, r.telefono::text, r.cedula_titular::text,
           r.banco::text, r.solicitado_en, u.nombre::text, u.cedula::text
      from public.retiros_bingo r join public.usuarios_bingo u on u.id = r.usuario_id
     where r.estado = 'pendiente' order by r.solicitado_en desc;
end;
$$;

create or replace function public.bingo_admin_listar_compras_seguro(p_token text)
returns table (
  id bigint, nombre text, telefono text, cedula text,
  cartones integer[], precio_total numeric, estado text, comprobante_url text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return query
    select a.id::bigint, a.nombre::text, a.telefono::text, a.cedula::text,
           a.cartones, a.precio_total, a.estado::text, a.comprobante_url::text
      from public.apartados_temp a
     order by a.id desc;
end;
$$;

create or replace function public.bingo_admin_listar_recuperaciones_seguro(p_token text)
returns table (id bigint, usuario_id integer, nombre text, cedula text, telefono text, solicitado_en timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  return query
    select r.id, u.id::integer, u.nombre::text, u.cedula::text, u.telefono::text, r.solicitado_en
      from public.recuperaciones_pin_bingo r join public.usuarios_bingo u on u.id = r.usuario_id
     where r.estado = 'pendiente' order by r.solicitado_en asc;
end;
$$;

-- Incluidas aqui para que la migracion sea autosuficiente aunque la
-- migracion de recuperacion anterior no se haya ejecutado todavia.
create or replace function public.bingo_admin_aprobar_recuperacion_pin(p_solicitud_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_usuario_id integer; v_pin_hash text;
begin
  select usuario_id, pin_hash_nuevo into v_usuario_id, v_pin_hash
    from public.recuperaciones_pin_bingo
   where id = p_solicitud_id and estado = 'pendiente' for update;
  if not found then return jsonb_build_object('ok', false, 'codigo', 'solicitud_no_disponible'); end if;
  update public.usuarios_bingo set pin_hash = v_pin_hash where id = v_usuario_id;
  delete from public.bingo_sesiones_cliente where usuario_id = v_usuario_id;
  update public.recuperaciones_pin_bingo set estado = 'aprobado', resuelto_en = now()
   where id = p_solicitud_id;
  return jsonb_build_object('ok', true, 'usuario_id', v_usuario_id);
end;
$$;

create or replace function public.bingo_admin_rechazar_recuperacion_pin(p_solicitud_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  update public.recuperaciones_pin_bingo set estado = 'rechazado', resuelto_en = now()
   where id = p_solicitud_id and estado = 'pendiente';
  if not found then return jsonb_build_object('ok', false, 'codigo', 'solicitud_no_disponible'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Wrappers de escritura: primero validan la sesión administrativa.
create or replace function public.bingo_admin_aprobar_recarga_seguro(p_token text, p_recarga_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_aprobar_recarga(p_recarga_id); end; $$;

create or replace function public.bingo_admin_rechazar_recarga_seguro(p_token text, p_recarga_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_rechazar_recarga(p_recarga_id); end; $$;

create or replace function public.bingo_admin_aprobar_retiro_seguro(p_token text, p_retiro_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_aprobar_retiro(p_retiro_id); end; $$;

create or replace function public.bingo_admin_rechazar_retiro_seguro(p_token text, p_retiro_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_rechazar_retiro(p_retiro_id); end; $$;

create or replace function public.bingo_admin_aprobar_recuperacion_seguro(p_token text, p_solicitud_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_aprobar_recuperacion_pin(p_solicitud_id); end; $$;

create or replace function public.bingo_admin_rechazar_recuperacion_seguro(p_token text, p_solicitud_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_rechazar_recuperacion_pin(p_solicitud_id); end; $$;

create or replace function public.bingo_admin_iniciar_juego_seguro(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_iniciar_juego(); end; $$;

create or replace function public.bingo_admin_sortear_bola_aleatoria_seguro(p_token text, p_juego_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_sortear_bola_aleatoria(p_juego_id); end; $$;

create or replace function public.bingo_admin_configurar_auto_juego_seguro(p_token text, p_juego_id bigint, p_activo boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_configurar_auto_juego(p_juego_id, p_activo); end; $$;

create or replace function public.bingo_admin_finalizar_juego_seguro(p_token text, p_juego_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_finalizar_juego(p_juego_id); end; $$;

create or replace function public.bingo_admin_configurar_ciclo_seguro(p_token text, p_activo boolean, p_minutos_entre_juegos integer, p_segundos_bola integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_configurar_ciclo(p_activo, p_minutos_entre_juegos, p_segundos_bola); end; $$;

create or replace function public.bingo_admin_reiniciar_ventas_seguro(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin perform public.bingo_admin_requerir_token(p_token); return public.bingo_admin_reiniciar_ventas(); end; $$;

create or replace function public.bingo_admin_guardar_config_seguro(p_token text, p_clave text, p_valor text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);
  if p_clave not in ('precio_carton', 'rotacion_cartones', 'cantidad_cartones_disponibles') then
    return jsonb_build_object('ok', false, 'codigo', 'clave_no_permitida');
  end if;
  insert into public.configuracion (clave, valor) values (p_clave, left(p_valor, 40))
  on conflict (clave) do update set valor = excluded.valor;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bingo_admin_promocion_seguro(
  p_token text, p_accion text, p_id bigint default null,
  p_nombre text default null, p_cantidad integer default null,
  p_precio numeric default null, p_descripcion text default null,
  p_activa boolean default true
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_id bigint;
begin
  perform public.bingo_admin_requerir_token(p_token);
  if p_accion = 'crear' then
    if length(trim(coalesce(p_nombre, ''))) < 2 or p_cantidad < 2 or p_precio <= 0 then
      return jsonb_build_object('ok', false, 'codigo', 'datos_invalidos');
    end if;
    insert into public.promociones_cartones (nombre, cantidad, precio, descripcion, activa, created_at)
    values (left(trim(p_nombre), 100), p_cantidad, p_precio, left(coalesce(p_descripcion, ''), 300), true, now())
    returning id into v_id;
  elsif p_accion = 'activar' then
    update public.promociones_cartones set activa = p_activa where id = p_id;
    v_id := p_id;
  elsif p_accion = 'eliminar' then
    delete from public.promociones_cartones where id = p_id;
    v_id := p_id;
  else
    return jsonb_build_object('ok', false, 'codigo', 'accion_invalida');
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- El navegador deja de poder leer hashes, correos y credenciales.
revoke select on public.usuarios_bingo from anon, authenticated;
revoke select, insert, update, delete on public.billeteras_bingo from anon, authenticated;
revoke select, insert, update, delete on public.billetera_movimientos from anon, authenticated;
revoke select, insert, update, delete on public.recargas_bingo from anon, authenticated;
revoke select, insert, update, delete on public.retiros_bingo from anon, authenticated;
revoke insert, update, delete on public.promociones_cartones from anon, authenticated;
revoke insert, update, delete on public.configuracion from anon, authenticated;

-- Cierra todas las funciones administrativas antiguas expuestas al rol público.
revoke execute on function public.bingo_admin_aprobar_compra(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_rechazar_compra(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_aprobar_compras_pendientes() from public, anon, authenticated;
revoke execute on function public.bingo_admin_aprobar_recarga(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_rechazar_recarga(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_aprobar_retiro(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_rechazar_retiro(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_aprobar_recuperacion_pin(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_rechazar_recuperacion_pin(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_iniciar_juego() from public, anon, authenticated;
revoke execute on function public.bingo_admin_sortear_bola(bigint, integer) from public, anon, authenticated;
revoke execute on function public.bingo_admin_sortear_bola_aleatoria(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_configurar_auto_juego(bigint, boolean) from public, anon, authenticated;
revoke execute on function public.bingo_admin_finalizar_juego(bigint) from public, anon, authenticated;
revoke execute on function public.bingo_admin_configurar_ciclo(boolean, integer, integer) from public, anon, authenticated;
revoke execute on function public.bingo_admin_reiniciar_ventas() from public, anon, authenticated;
revoke execute on function public.bingo_reservar_cartones(bigint, text, text, text, text, integer[], numeric, bigint) from public, anon, authenticated;
revoke execute on function public.bingo_pagar_con_saldo(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.bingo_liberar_reserva(bigint) from public, anon, authenticated;

-- Helpers internos nunca se exponen directamente.
revoke all on function public.bingo_consumir_rate_limit(text, text, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.bingo_origen_peticion() from public, anon, authenticated;
revoke all on function public.bingo_crear_token() from public, anon, authenticated;
revoke all on function public.bingo_token_hash(text) from public, anon, authenticated;
revoke all on function public.bingo_usuario_por_token(text) from public, anon, authenticated;
revoke all on function public.bingo_admin_requerir_token(text) from public, anon, authenticated;
revoke all on function public.bingo_configurar_admin_seguro(text, text) from public, anon, authenticated;

revoke all on function public.bingo_registrar_usuario(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.bingo_solicitar_recuperacion_pin(text, text, text) from public, anon, authenticated;

grant execute on function public.bingo_registrar_usuario(text, text, text, text, text) to anon, authenticated;
grant execute on function public.bingo_solicitar_recuperacion_pin(text, text, text) to anon, authenticated;
grant execute on function public.bingo_login_cliente_seguro(text, text, text) to anon, authenticated;
grant execute on function public.bingo_validar_sesion_cliente(text) to anon, authenticated;
grant execute on function public.bingo_cerrar_sesion_cliente(text) to anon, authenticated;
grant execute on function public.bingo_cliente_cuenta_segura(text) to anon, authenticated;
grant execute on function public.bingo_cliente_movimientos_seguro(text) to anon, authenticated;
grant execute on function public.bingo_cliente_solicitar_recarga_seguro(text, numeric, text, text) to anon, authenticated;
grant execute on function public.bingo_cliente_solicitar_retiro_seguro(text, numeric, text, text, text) to anon, authenticated;
grant execute on function public.bingo_reservar_cartones_seguro(text, integer[], bigint) to anon, authenticated;
grant execute on function public.bingo_pagar_con_saldo_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_liberar_reserva_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_login_seguro(text, text) to anon, authenticated;
grant execute on function public.bingo_admin_validar_sesion_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_logout_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_listar_clientes_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_listar_recargas_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_listar_retiros_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_listar_compras_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_listar_recuperaciones_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_aprobar_recarga_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_rechazar_recarga_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_aprobar_retiro_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_rechazar_retiro_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_aprobar_recuperacion_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_rechazar_recuperacion_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_iniciar_juego_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_sortear_bola_aleatoria_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_configurar_auto_juego_seguro(text, bigint, boolean) to anon, authenticated;
grant execute on function public.bingo_admin_finalizar_juego_seguro(text, bigint) to anon, authenticated;
grant execute on function public.bingo_admin_configurar_ciclo_seguro(text, boolean, integer, integer) to anon, authenticated;
grant execute on function public.bingo_admin_reiniciar_ventas_seguro(text) to anon, authenticated;
grant execute on function public.bingo_admin_guardar_config_seguro(text, text, text) to anon, authenticated;
grant execute on function public.bingo_admin_promocion_seguro(text, text, bigint, text, integer, numeric, text, boolean) to anon, authenticated;

notify pgrst, 'reload schema';

commit;

-- IMPORTANTE: después de ejecutar esta migración, configura la cuenta admin
-- UNA SOLA VEZ desde el SQL Editor (esta función no es accesible por la web):
-- select public.bingo_configurar_admin_seguro('tu_usuario', 'una-clave-de-14-o-mas-caracteres');
