-- Recuperación de PIN asistida por el administrador.
-- Migración nueva e idempotente: no repite las migraciones anteriores.

begin;

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
  on public.recuperaciones_pin_bingo (usuario_id)
  where estado = 'pendiente';

create index if not exists idx_recuperaciones_pin_estado_fecha
  on public.recuperaciones_pin_bingo (estado, solicitado_en desc);

alter table public.recuperaciones_pin_bingo enable row level security;
revoke all on public.recuperaciones_pin_bingo from anon, authenticated;
revoke all on sequence public.recuperaciones_pin_bingo_id_seq from anon, authenticated;

create or replace function public.bingo_solicitar_recuperacion_pin(
  p_cedula text,
  p_telefono text,
  p_pin_hash_nuevo text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_usuario_id integer;
  v_solicitud_id bigint;
  v_cedula_limpia text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_telefono_limpio text := regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g');
begin
  if length(v_cedula_limpia) < 6 or length(v_telefono_limpio) < 10 then
    return jsonb_build_object('ok', false, 'codigo', 'datos_invalidos');
  end if;

  if not (
    coalesce(p_pin_hash_nuevo, '') ~ '^[0-9a-f]{64}$'
    or coalesce(p_pin_hash_nuevo, '') ~ '^[0-9]{4,12}$'
  ) then
    return jsonb_build_object('ok', false, 'codigo', 'pin_invalido');
  end if;

  select id
    into v_usuario_id
    from public.usuarios_bingo
   where activo = true
     and regexp_replace(coalesce(cedula, ''), '\D', '', 'g') = v_cedula_limpia
     and right(regexp_replace(coalesce(telefono, ''), '\D', '', 'g'), 10)
         = right(v_telefono_limpio, 10)
   limit 1;

  if not found then
    -- Respuesta genérica para no revelar qué dato fue el incorrecto.
    return jsonb_build_object('ok', false, 'codigo', 'datos_no_coinciden');
  end if;

  perform pg_advisory_xact_lock(75002, 8);

  update public.recuperaciones_pin_bingo
     set telefono_verificado = v_telefono_limpio,
         pin_hash_nuevo = p_pin_hash_nuevo,
         solicitado_en = now()
   where usuario_id = v_usuario_id
     and estado = 'pendiente'
  returning id into v_solicitud_id;

  if not found then
    insert into public.recuperaciones_pin_bingo (
      usuario_id, telefono_verificado, pin_hash_nuevo
    ) values (
      v_usuario_id, v_telefono_limpio, p_pin_hash_nuevo
    )
    returning id into v_solicitud_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'solicitud_id', v_solicitud_id,
    'estado', 'pendiente'
  );
end;
$$;

create or replace function public.bingo_admin_listar_recuperaciones_pin()
returns table (
  id bigint,
  usuario_id integer,
  nombre text,
  cedula text,
  telefono text,
  solicitado_en timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select r.id, u.id, u.nombre, u.cedula, u.telefono, r.solicitado_en
    from public.recuperaciones_pin_bingo r
    join public.usuarios_bingo u on u.id = r.usuario_id
   where r.estado = 'pendiente'
   order by r.solicitado_en asc;
$$;

create or replace function public.bingo_admin_aprobar_recuperacion_pin(
  p_solicitud_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_usuario_id integer;
  v_pin_hash text;
begin
  select usuario_id, pin_hash_nuevo
    into v_usuario_id, v_pin_hash
    from public.recuperaciones_pin_bingo
   where id = p_solicitud_id
     and estado = 'pendiente'
   for update;

  if not found then
    return jsonb_build_object('ok', false, 'codigo', 'solicitud_no_disponible');
  end if;

  update public.usuarios_bingo
     set pin_hash = v_pin_hash
   where id = v_usuario_id;

  update public.recuperaciones_pin_bingo
     set estado = 'aprobado', resuelto_en = now()
   where id = p_solicitud_id;

  return jsonb_build_object('ok', true, 'usuario_id', v_usuario_id);
end;
$$;

create or replace function public.bingo_admin_rechazar_recuperacion_pin(
  p_solicitud_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.recuperaciones_pin_bingo
     set estado = 'rechazado', resuelto_en = now()
   where id = p_solicitud_id
     and estado = 'pendiente';

  if not found then
    return jsonb_build_object('ok', false, 'codigo', 'solicitud_no_disponible');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.bingo_solicitar_recuperacion_pin(text, text, text) from public;
revoke all on function public.bingo_admin_listar_recuperaciones_pin() from public;
revoke all on function public.bingo_admin_aprobar_recuperacion_pin(bigint) from public;
revoke all on function public.bingo_admin_rechazar_recuperacion_pin(bigint) from public;

grant execute on function public.bingo_solicitar_recuperacion_pin(text, text, text) to anon, authenticated;
grant execute on function public.bingo_admin_listar_recuperaciones_pin() to anon, authenticated;
grant execute on function public.bingo_admin_aprobar_recuperacion_pin(bigint) to anon, authenticated;
grant execute on function public.bingo_admin_rechazar_recuperacion_pin(bigint) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
