-- Corrige los DELETE totales bloqueados por pgsafeupdate.
-- Migracion incremental: ejecutar una sola vez despues de AHORRO_REALTIME_V1.

begin;

create or replace function public.bingo_emitir_evento_sala_optimizado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tipo text;
begin
  if tg_op = 'INSERT' then
    v_tipo := 'estado';
  elsif new.estado = 'finalizado' and old.estado is distinct from new.estado then
    v_tipo := 'final';
  elsif old.premio_fila_ganador_id is distinct from new.premio_fila_ganador_id
     or old.premio_columna_ganador_id is distinct from new.premio_columna_ganador_id then
    v_tipo := 'premio';
  elsif old.estado is distinct from new.estado
     or old.auto_bolas is distinct from new.auto_bolas
     or old.proximo_juego_en is distinct from new.proximo_juego_en then
    v_tipo := 'estado';
  else
    return new;
  end if;

  insert into public.bingo_eventos_sala (juego_id, tipo, datos)
  values (
    new.id,
    v_tipo,
    jsonb_build_object(
      'estado', new.estado,
      'ganador_id', new.ganador_id,
      'ganador_nombre', new.ganador_nombre,
      'premio_fila_ganador_id', new.premio_fila_ganador_id,
      'premio_columna_ganador_id', new.premio_columna_ganador_id,
      'auto_bolas', new.auto_bolas,
      'proximo_juego_en', new.proximo_juego_en
    )
  );

  delete from public.bingo_eventos_sala
   where creado_en < now() - interval '2 days';

  if v_tipo = 'final' then
    delete from public.bingo_sesiones_sala
     where usuario_id is not null;
  end if;
  return new;
end;
$$;

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

  delete from public.cartones_apartados
   where numero_carton is not null;
  get diagnostics v_apartados = row_count;

  delete from public.cartones_vendidos
   where numero_carton is not null;
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

  delete from public.cartones_apartados
   where numero_carton is not null;
  get diagnostics v_apartados = row_count;

  delete from public.cartones_vendidos
   where numero_carton is not null;
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

  delete from public.bingo_admin_sesiones
   where token_hash is not null;
end;
$$;

notify pgrst, 'reload schema';

commit;
