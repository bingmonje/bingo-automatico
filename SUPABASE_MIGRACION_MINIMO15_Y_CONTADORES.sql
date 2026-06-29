-- Minimo de cartones para iniciar y estado publico de la programacion.

insert into public.config_bingo_auto (clave, valor, updated_at)
values ('min_cartones_inicio', '15', now())
on conflict (clave) do update
set valor = excluded.valor, updated_at = excluded.updated_at;

create or replace function public.bingo_estado_programacion()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_cartones integer := 0;
  v_minimo integer := 15;
begin
  select count(*) into v_cartones from public.cartones_vendidos;

  select greatest(1, least(1000,
    case when valor ~ '^[0-9]+$' then valor::integer else 15 end
  )) into v_minimo
  from public.config_bingo_auto
  where clave = 'min_cartones_inicio';
  v_minimo := coalesce(v_minimo, 15);

  select * into v_juego
  from public.bingo_automatico
  order by id desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'juego', case when v_juego.id is null then null else to_jsonb(v_juego) end,
    'cartones_vendidos', v_cartones,
    'minimo_cartones', v_minimo,
    'faltantes', greatest(0, v_minimo - v_cartones)
  );
end;
$function$;

grant execute on function public.bingo_estado_programacion() to anon, authenticated;

create or replace function public.bingo_admin_iniciar_juego()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_juego public.bingo_automatico%rowtype;
  v_segundos integer := 5;
  v_vendidos integer := 0;
  v_minimo integer := 15;
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

  select count(*) into v_vendidos from public.cartones_vendidos;
  select greatest(1, least(1000,
    case when valor ~ '^[0-9]+$' then valor::integer else 15 end
  )) into v_minimo
  from public.config_bingo_auto
  where clave = 'min_cartones_inicio';
  v_minimo := coalesce(v_minimo, 15);

  if v_vendidos < v_minimo then
    return jsonb_build_object(
      'ok', false,
      'codigo', 'cartones_insuficientes',
      'cartones_vendidos', v_vendidos,
      'minimo_cartones', v_minimo,
      'faltantes', v_minimo - v_vendidos
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
  v_minimo integer := 15;
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
                           then valor::integer end), 5),
         coalesce(max(case when clave = 'min_cartones_inicio' and valor ~ '^[0-9]+$'
                           then valor::integer end), 15)
  into v_ciclo, v_minutos, v_segundos, v_minimo
  from public.config_bingo_auto;

  v_minutos := greatest(1, least(1440, v_minutos));
  v_segundos := greatest(5, least(60, v_segundos));
  v_minimo := greatest(1, least(1000, v_minimo));

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

    if v_vendidos < v_minimo then
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


