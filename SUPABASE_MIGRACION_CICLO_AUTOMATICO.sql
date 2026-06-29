-- Ciclo automatico y sorteo del lado del servidor.
-- Disenada para ejecutarse una sola vez mediante Supabase migrations.

create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

alter table public.bingo_automatico
  add column if not exists auto_bolas boolean not null default false,
  add column if not exists intervalo_bolas_segundos integer not null default 5,
  add column if not exists proxima_bola_en timestamptz,
  add column if not exists proximo_juego_en timestamptz,
  add column if not exists fin_estimado_en timestamptz;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bingo_intervalo_bolas_valido'
      and conrelid = 'public.bingo_automatico'::regclass
  ) then
    alter table public.bingo_automatico
      add constraint bingo_intervalo_bolas_valido
      check (intervalo_bolas_segundos between 5 and 60);
  end if;
end
$migration$;

insert into public.config_bingo_auto (clave, valor)
values
  ('ciclo_automatico', 'false'),
  ('minutos_entre_juegos', '60')
on conflict (clave) do nothing;

update public.config_bingo_auto
set valor = '5', updated_at = now()
where clave = 'tiempo_auto'
  and (valor !~ '^[0-9]+$' or valor::integer < 5 or valor::integer > 60);

create or replace function public.bingo_servidor_procesar_premios(p_juego_id bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_bolas integer[];
  v_rotacion integer := 0;
  v_ganador integer;
begin
  select * into v_juego
  from public.bingo_automatico
  where id = p_juego_id
  for update;

  if not found or v_juego.estado <> 'jugando' then return; end if;

  select coalesce(array_agg(distinct numero order by numero), '{}')
  into v_bolas
  from public.bolas_auto
  where juego_id = p_juego_id;

  select case when valor ~ '^[0-9]+$' then valor::integer else 0 end
  into v_rotacion
  from public.configuracion
  where clave = 'rotacion_cartones';
  v_rotacion := coalesce(v_rotacion, 0);

  if not coalesce(v_juego.premio_fila_pagado, false) then
    select min(numero_carton) into v_ganador
    from public.cartones_vendidos
    where public.bingo_carton_gana(numero_carton, v_rotacion, v_bolas, 'fila');

    if v_ganador is not null then
      perform public.bingo_reclamar_premio(
        p_juego_id, 'fila', v_ganador, 'Servidor automatico',
        array[v_ganador], 0
      );
    end if;
  end if;

  select * into v_juego
  from public.bingo_automatico
  where id = p_juego_id;

  if v_juego.estado = 'jugando'
     and not coalesce(v_juego.premio_columna_pagado, false) then
    select min(numero_carton) into v_ganador
    from public.cartones_vendidos
    where public.bingo_carton_gana(numero_carton, v_rotacion, v_bolas, 'columna');

    if v_ganador is not null then
      perform public.bingo_reclamar_premio(
        p_juego_id, 'columna', v_ganador, 'Servidor automatico',
        array[v_ganador], 0
      );
    end if;
  end if;

  select * into v_juego
  from public.bingo_automatico
  where id = p_juego_id;

  if v_juego.estado = 'jugando'
     and coalesce(v_juego.premio_fila_pagado, false)
     and coalesce(v_juego.premio_columna_pagado, false) then
    select min(numero_carton) into v_ganador
    from public.cartones_vendidos
    where public.bingo_carton_gana(numero_carton, v_rotacion, v_bolas, 'final');

    if v_ganador is not null then
      perform public.bingo_reclamar_premio(
        p_juego_id, 'final', v_ganador, 'Servidor automatico',
        array[v_ganador], 0
      );

      update public.bingo_automatico
      set auto_bolas = false,
          proxima_bola_en = null,
          fin_estimado_en = now()
      where id = p_juego_id and estado = 'finalizado';
    end if;
  end if;
end;
$function$;

revoke all on function public.bingo_servidor_procesar_premios(bigint) from public, anon, authenticated;

create or replace function public.bingo_admin_iniciar_juego()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_segundos integer := 5;
begin
  perform pg_advisory_xact_lock(75002, 1);

  select * into v_juego
  from public.bingo_automatico
  where estado = 'jugando'
  order by id desc limit 1
  for update;

  if found then
    return jsonb_build_object(
      'ok', false, 'codigo', 'juego_ya_activo', 'juego', to_jsonb(v_juego)
    );
  end if;

  select greatest(5, least(60,
    case when valor ~ '^[0-9]+$' then valor::integer else 5 end
  )) into v_segundos
  from public.config_bingo_auto
  where clave = 'tiempo_auto';
  v_segundos := coalesce(v_segundos, 5);

  select * into v_juego
  from public.bingo_automatico
  where estado = 'esperando'
  order by id desc limit 1
  for update;

  if found then
    update public.bingo_automatico
    set estado = 'jugando',
        iniciado_en = now(),
        finalizado_en = null,
        limpieza_completada = false,
        auto_bolas = true,
        intervalo_bolas_segundos = v_segundos,
        proxima_bola_en = now() + make_interval(secs => v_segundos),
        proximo_juego_en = null,
        fin_estimado_en = now() + make_interval(secs => 75 * v_segundos)
    where id = v_juego.id
    returning * into v_juego;
  else
    insert into public.bingo_automatico (
      estado, iniciado_en, limpieza_completada, auto_bolas,
      intervalo_bolas_segundos, proxima_bola_en, fin_estimado_en
    ) values (
      'jugando', now(), false, true,
      v_segundos, now() + make_interval(secs => v_segundos),
      now() + make_interval(secs => 75 * v_segundos)
    ) returning * into v_juego;
  end if;

  return jsonb_build_object('ok', true, 'juego', to_jsonb(v_juego));
end;
$function$;

create or replace function public.bingo_admin_sortear_bola(
  p_juego_id bigint,
  p_numero integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_bola public.bolas_auto%rowtype;
  v_letra char(1);
  v_cantidad integer := 0;
begin
  if p_numero < 1 or p_numero > 75 then raise exception 'Bola invalida'; end if;

  select * into v_juego
  from public.bingo_automatico
  where id = p_juego_id
  for update;

  if not found then raise exception 'Juego no encontrado'; end if;
  if v_juego.estado <> 'jugando' then
    return jsonb_build_object('ok', false, 'codigo', 'juego_no_activo');
  end if;

  if exists (
    select 1 from public.bolas_auto
    where juego_id = p_juego_id and numero = p_numero
  ) then
    return jsonb_build_object('ok', false, 'codigo', 'bola_duplicada');
  end if;

  v_letra := case
    when p_numero <= 15 then 'B'
    when p_numero <= 30 then 'I'
    when p_numero <= 45 then 'N'
    when p_numero <= 60 then 'G'
    else 'O'
  end;

  insert into public.bolas_auto (juego_id, numero, letra)
  values (p_juego_id, p_numero, v_letra)
  returning * into v_bola;

  select count(*) into v_cantidad
  from public.bolas_auto
  where juego_id = p_juego_id;

  update public.bingo_automatico
  set proxima_bola_en = case when auto_bolas
        then now() + make_interval(secs => intervalo_bolas_segundos)
        else null end,
      fin_estimado_en = case when auto_bolas
        then now() + make_interval(secs => greatest(0, 75 - v_cantidad) * intervalo_bolas_segundos)
        else null end
  where id = p_juego_id;

  perform public.bingo_servidor_procesar_premios(p_juego_id);

  return jsonb_build_object('ok', true, 'bola', to_jsonb(v_bola));
end;
$function$;

create or replace function public.bingo_admin_sortear_bola_aleatoria(p_juego_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_estado text;
  v_numero integer;
begin
  select estado into v_estado
  from public.bingo_automatico
  where id = p_juego_id
  for update;

  if not found then raise exception 'Juego no encontrado'; end if;
  if v_estado <> 'jugando' then
    return jsonb_build_object('ok', false, 'codigo', 'juego_no_activo');
  end if;

  select n into v_numero
  from generate_series(1, 75) as n
  where not exists (
    select 1 from public.bolas_auto b
    where b.juego_id = p_juego_id and b.numero = n
  )
  order by random()
  limit 1;

  if v_numero is null then
    return jsonb_build_object('ok', false, 'codigo', 'sin_bolas');
  end if;

  return public.bingo_admin_sortear_bola(p_juego_id, v_numero);
end;
$function$;

create or replace function public.bingo_admin_configurar_auto_juego(
  p_juego_id bigint,
  p_activo boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_cantidad integer := 0;
  v_segundos integer := 5;
begin
  select * into v_juego
  from public.bingo_automatico
  where id = p_juego_id
  for update;

  if not found then raise exception 'Juego no encontrado'; end if;
  if v_juego.estado <> 'jugando' then
    return jsonb_build_object('ok', false, 'codigo', 'juego_no_activo');
  end if;

  select count(*) into v_cantidad
  from public.bolas_auto
  where juego_id = p_juego_id;

  select greatest(5, least(60,
    case when valor ~ '^[0-9]+$' then valor::integer else 5 end
  )) into v_segundos
  from public.config_bingo_auto
  where clave = 'tiempo_auto';
  v_segundos := coalesce(v_segundos, v_juego.intervalo_bolas_segundos, 5);

  update public.bingo_automatico
  set auto_bolas = p_activo,
      intervalo_bolas_segundos = v_segundos,
      proxima_bola_en = case when p_activo
        then now() + make_interval(secs => v_segundos) else null end,
      fin_estimado_en = case when p_activo
        then now() + make_interval(secs => greatest(0, 75 - v_cantidad) * v_segundos)
        else null end
  where id = p_juego_id
  returning * into v_juego;

  return jsonb_build_object('ok', true, 'juego', to_jsonb(v_juego));
end;
$function$;

create or replace function public.bingo_cerrar_juego(p_juego_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_vendidos integer := 0;
  v_apartados integer := 0;
begin
  select * into v_juego
  from public.bingo_automatico
  where id = p_juego_id
  for update;

  if not found then raise exception 'Juego no encontrado'; end if;
  if v_juego.estado <> 'finalizado' then
    return jsonb_build_object('ok', false, 'codigo', 'juego_no_finalizado');
  end if;

  if v_juego.limpieza_completada then
    return jsonb_build_object('ok', true, 'duplicado', true);
  end if;

  delete from public.cartones_apartados;
  get diagnostics v_apartados = row_count;

  delete from public.cartones_vendidos;
  get diagnostics v_vendidos = row_count;

  update public.apartados_temp
  set estado = 'cerrado'
  where estado in ('apartado', 'pendiente', 'aprobado');

  update public.bingo_automatico
  set limpieza_completada = true,
      auto_bolas = false,
      proxima_bola_en = null,
      fin_estimado_en = coalesce(fin_estimado_en, finalizado_en, now())
  where id = p_juego_id;

  return jsonb_build_object(
    'ok', true,
    'cartones_liberados', v_vendidos,
    'reservas_liberadas', v_apartados
  );
end;
$function$;

create or replace function public.bingo_admin_finalizar_juego(p_juego_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
begin
  perform pg_advisory_xact_lock(75002, 1);

  select * into v_juego
  from public.bingo_automatico
  where id = p_juego_id
  for update;

  if not found then raise exception 'Juego no encontrado'; end if;
  if v_juego.estado = 'finalizado' then
    return jsonb_build_object('ok', true, 'duplicado', true, 'juego', to_jsonb(v_juego));
  end if;

  update public.bingo_automatico
  set estado = 'finalizado',
      finalizado_en = now(),
      auto_bolas = false,
      proxima_bola_en = null,
      fin_estimado_en = now()
  where id = p_juego_id
  returning * into v_juego;

  return jsonb_build_object('ok', true, 'juego', to_jsonb(v_juego));
end;
$function$;

create or replace function public.bingo_admin_configurar_ciclo(
  p_activo boolean,
  p_minutos_entre_juegos integer default 60,
  p_segundos_bola integer default 5
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_ultimo_final public.bingo_automatico%rowtype;
begin
  if p_minutos_entre_juegos < 1 or p_minutos_entre_juegos > 1440 then
    raise exception 'Los minutos deben estar entre 1 y 1440';
  end if;
  if p_segundos_bola < 5 or p_segundos_bola > 60 then
    raise exception 'Los segundos entre bolas deben estar entre 5 y 60';
  end if;

  perform pg_advisory_xact_lock(75002, 1);

  insert into public.config_bingo_auto (clave, valor, updated_at)
  values
    ('ciclo_automatico', case when p_activo then 'true' else 'false' end, now()),
    ('minutos_entre_juegos', p_minutos_entre_juegos::text, now()),
    ('tiempo_auto', p_segundos_bola::text, now())
  on conflict (clave) do update
  set valor = excluded.valor, updated_at = excluded.updated_at;

  select * into v_juego
  from public.bingo_automatico
  where estado = 'jugando'
  order by id desc limit 1
  for update;

  if found then
    update public.bingo_automatico
    set intervalo_bolas_segundos = p_segundos_bola,
        auto_bolas = case when p_activo then true else auto_bolas end,
        proxima_bola_en = case
          when p_activo then now() + make_interval(secs => p_segundos_bola)
          else proxima_bola_en end
    where id = v_juego.id
    returning * into v_juego;
  elsif p_activo then
    select * into v_ultimo_final
    from public.bingo_automatico
    where estado = 'finalizado'
    order by id desc limit 1
    for update;

    if found and not v_ultimo_final.limpieza_completada then
      perform public.bingo_cerrar_juego(v_ultimo_final.id);
    end if;

    select * into v_juego
    from public.bingo_automatico
    where estado = 'esperando'
    order by id desc limit 1
    for update;

    if found then
      update public.bingo_automatico
      set proximo_juego_en = now() + make_interval(mins => p_minutos_entre_juegos),
          intervalo_bolas_segundos = p_segundos_bola,
          auto_bolas = false,
          proxima_bola_en = null,
          fin_estimado_en = null
      where id = v_juego.id
      returning * into v_juego;
    else
      insert into public.bingo_automatico (
        estado, proximo_juego_en, intervalo_bolas_segundos,
        auto_bolas, limpieza_completada
      ) values (
        'esperando', now() + make_interval(mins => p_minutos_entre_juegos),
        p_segundos_bola, false, true
      ) returning * into v_juego;
    end if;
  else
    update public.bingo_automatico
    set proximo_juego_en = null
    where estado = 'esperando'
    returning * into v_juego;
  end if;

  return jsonb_build_object(
    'ok', true,
    'activo', p_activo,
    'minutos_entre_juegos', p_minutos_entre_juegos,
    'segundos_bola', p_segundos_bola,
    'juego', case when v_juego.id is null then null else to_jsonb(v_juego) end
  );
end;
$function$;

create or replace function public.bingo_servidor_tick()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_tiene_lock boolean;
  v_ciclo boolean := false;
  v_minutos integer := 60;
  v_segundos integer := 5;
  v_juego public.bingo_automatico%rowtype;
  v_ultimo_final public.bingo_automatico%rowtype;
  v_numero integer;
  v_vendidos integer := 0;
begin
  v_tiene_lock := pg_try_advisory_xact_lock(75002, 1);
  if not v_tiene_lock then return; end if;

  select coalesce(bool_or(valor = 'true') filter (where clave = 'ciclo_automatico'), false),
         coalesce(max(case when clave = 'minutos_entre_juegos' and valor ~ '^[0-9]+$'
                           then valor::integer end), 60),
         coalesce(max(case when clave = 'tiempo_auto' and valor ~ '^[0-9]+$'
                           then valor::integer end), 5)
  into v_ciclo, v_minutos, v_segundos
  from public.config_bingo_auto;

  v_minutos := greatest(1, least(1440, v_minutos));
  v_segundos := greatest(5, least(60, v_segundos));

  select * into v_juego
  from public.bingo_automatico
  where estado = 'jugando'
  order by id desc limit 1
  for update;

  if found then
    if v_juego.auto_bolas
       and coalesce(v_juego.proxima_bola_en, now()) <= now() then
      select n into v_numero
      from generate_series(1, 75) as n
      where not exists (
        select 1 from public.bolas_auto b
        where b.juego_id = v_juego.id and b.numero = n
      )
      order by random()
      limit 1;

      if v_numero is null then
        perform public.bingo_servidor_procesar_premios(v_juego.id);
        update public.bingo_automatico
        set auto_bolas = false, proxima_bola_en = null, fin_estimado_en = now()
        where id = v_juego.id and estado = 'jugando';
      else
        perform public.bingo_admin_sortear_bola(v_juego.id, v_numero);
      end if;
    end if;
    return;
  end if;

  select * into v_ultimo_final
  from public.bingo_automatico
  where estado = 'finalizado'
  order by id desc limit 1
  for update;

  if found and not v_ultimo_final.limpieza_completada then
    perform public.bingo_cerrar_juego(v_ultimo_final.id);
  end if;

  if not v_ciclo then return; end if;

  select * into v_juego
  from public.bingo_automatico
  where estado = 'esperando'
  order by id desc limit 1
  for update;

  if not found then
    insert into public.bingo_automatico (
      estado, proximo_juego_en, intervalo_bolas_segundos,
      auto_bolas, limpieza_completada
    ) values (
      'esperando',
      coalesce(v_ultimo_final.finalizado_en, now()) + make_interval(mins => v_minutos),
      v_segundos, false, true
    ) returning * into v_juego;
  end if;

  if v_juego.proximo_juego_en is null then
    update public.bingo_automatico
    set proximo_juego_en = now() + make_interval(mins => v_minutos),
        intervalo_bolas_segundos = v_segundos
    where id = v_juego.id
    returning * into v_juego;
  end if;

  if v_juego.proximo_juego_en <= now() then
    select count(*) into v_vendidos from public.cartones_vendidos;

    if v_vendidos = 0 then
      update public.bingo_automatico
      set proximo_juego_en = now() + interval '1 minute'
      where id = v_juego.id;
      return;
    end if;

    update public.bingo_automatico
    set estado = 'jugando',
        iniciado_en = now(),
        finalizado_en = null,
        limpieza_completada = false,
        auto_bolas = true,
        intervalo_bolas_segundos = v_segundos,
        proxima_bola_en = now() + make_interval(secs => v_segundos),
        proximo_juego_en = null,
        fin_estimado_en = now() + make_interval(secs => 75 * v_segundos)
    where id = v_juego.id;
  end if;
end;
$function$;

revoke all on function public.bingo_servidor_tick() from public, anon, authenticated;

create or replace function public.bingo_admin_reiniciar_ventas()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_apartados integer := 0;
  v_vendidos integer := 0;
  v_juegos_finalizados integer := 0;
begin
  perform pg_advisory_xact_lock(75002, 1);

  insert into public.config_bingo_auto (clave, valor, updated_at)
  values ('ciclo_automatico', 'false', now())
  on conflict (clave) do update
  set valor = excluded.valor, updated_at = excluded.updated_at;

  update public.bingo_automatico
  set estado = 'finalizado',
      finalizado_en = now(),
      auto_bolas = false,
      proxima_bola_en = null,
      proximo_juego_en = null,
      fin_estimado_en = now()
  where estado = 'jugando';
  get diagnostics v_juegos_finalizados = row_count;

  update public.bingo_automatico
  set proximo_juego_en = null
  where estado = 'esperando';

  delete from public.cartones_apartados;
  get diagnostics v_apartados = row_count;

  delete from public.cartones_vendidos;
  get diagnostics v_vendidos = row_count;

  update public.apartados_temp
  set estado = 'rechazado'
  where estado in ('apartado', 'pendiente', 'aprobado');

  return jsonb_build_object(
    'ok', true,
    'reservas_liberadas', v_apartados,
    'cartones_liberados', v_vendidos,
    'juegos_finalizados', v_juegos_finalizados
  );
end;
$function$;

grant execute on function public.bingo_admin_sortear_bola_aleatoria(bigint) to anon, authenticated;
grant execute on function public.bingo_admin_configurar_auto_juego(bigint, boolean) to anon, authenticated;
grant execute on function public.bingo_admin_finalizar_juego(bigint) to anon, authenticated;
grant execute on function public.bingo_admin_configurar_ciclo(boolean, integer, integer) to anon, authenticated;

select cron.schedule(
  'bingo-servidor-tick',
  '5 seconds',
  $job$select public.bingo_servidor_tick();$job$
);

select cron.schedule(
  'bingo-limpiar-cron-historial',
  '17 3 * * *',
  $job$delete from cron.job_run_details where end_time < now() - interval '7 days';$job$
);


