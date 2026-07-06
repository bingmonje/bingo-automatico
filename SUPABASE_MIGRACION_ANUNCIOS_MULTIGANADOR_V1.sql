-- SUPABASE_MIGRACION_ANUNCIOS_MULTIGANADOR_V1.sql
-- Guarda y transmite todos los nombres/cartones que ganan el mismo premio.

begin;
create or replace function public.bingo_reclamar_premio(
  p_juego_id bigint,
  p_tipo_premio text,
  p_carton_ganador integer,
  p_ganador_nombre text,
  p_ganadores integer[],
  p_premio_total numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_juego public.bingo_automatico%rowtype;
  v_bolas integer[];
  v_rotacion integer := 0;
  v_ganadores integer[];
  v_total integer;
  v_recaudado numeric;
  v_premio_total numeric;
  v_monto numeric;
  v_numero integer;
  v_vendido public.cartones_vendidos%rowtype;
  v_usuario public.usuarios_bingo%rowtype;
  v_billetera public.billeteras_bingo%rowtype;
  v_saldo_anterior numeric;
  v_saldo_nuevo numeric;
  v_pagado boolean;
  v_ganadores_texto text;
begin
  if p_tipo_premio not in ('fila', 'columna', 'final') then
    raise exception 'Tipo de premio invalido';
  end if;

  select * into v_juego from public.bingo_automatico
   where id = p_juego_id for update;
  if not found then raise exception 'Juego no encontrado'; end if;
  if v_juego.estado <> 'jugando' then
    return jsonb_build_object('ok', false, 'codigo', 'juego_no_activo');
  end if;

  v_pagado := case p_tipo_premio
    when 'fila' then coalesce(v_juego.premio_fila_pagado, false)
    when 'columna' then coalesce(v_juego.premio_columna_pagado, false)
    else coalesce(v_juego.premio_final_pagado, false)
  end;

  if v_pagado then return jsonb_build_object('ok', true, 'duplicado', true); end if;

  if p_tipo_premio = 'final' and (
    not coalesce(v_juego.premio_fila_pagado, false) or
    not coalesce(v_juego.premio_columna_pagado, false)
  ) then
    return jsonb_build_object('ok', false, 'codigo', 'premios_previos_pendientes');
  end if;

  select coalesce(array_agg(distinct numero order by numero), '{}')
    into v_bolas
    from public.bolas_auto
   where juego_id = p_juego_id;

  select case when valor ~ '^[0-9]+$' then valor::integer else 0 end
    into v_rotacion
    from public.configuracion
   where clave = 'rotacion_cartones';
  v_rotacion := coalesce(v_rotacion, 0);

  select array_agg(cv.numero_carton order by cv.numero_carton)
    into v_ganadores
    from public.cartones_vendidos cv
   where public.bingo_carton_gana(cv.numero_carton, v_rotacion, v_bolas, p_tipo_premio);

  v_total := coalesce(array_length(v_ganadores, 1), 0);
  if v_total = 0 then return jsonb_build_object('ok', false, 'codigo', 'sin_ganadores'); end if;
  if not (p_carton_ganador = any(v_ganadores)) then
    return jsonb_build_object('ok', false, 'codigo', 'carton_no_ganador');
  end if;

  select coalesce(sum(precio_total), 0) into v_recaudado
    from public.apartados_temp where estado = 'aprobado';

  v_premio_total := round(v_recaudado * 0.70 * case p_tipo_premio
    when 'final' then 0.60 else 0.20 end, 2);
  if v_premio_total <= 0 then raise exception 'Premio no configurado'; end if;
  v_monto := round(v_premio_total / v_total, 2);

  select string_agg(
           coalesce(nullif(trim(cv.nombre), ''), 'Jugador') ||
           ' — Cartón #' || cv.numero_carton,
           E'\n' order by cv.numero_carton
         )
    into v_ganadores_texto
    from public.cartones_vendidos cv
   where cv.numero_carton = any(v_ganadores);

  v_ganadores_texto := coalesce(
    nullif(v_ganadores_texto, ''),
    coalesce(nullif(trim(p_ganador_nombre), ''), 'Jugador') ||
    ' — Cartón #' || p_carton_ganador
  );

  select * into v_vendido from public.cartones_vendidos
   where numero_carton = p_carton_ganador;

  if p_tipo_premio = 'fila' then
    update public.bingo_automatico
       set premio_fila_ganador_id = p_carton_ganador,
           premio_fila_ganador_nombre = v_ganadores_texto,
           premio_fila_pagado = true
     where id = p_juego_id;
  elsif p_tipo_premio = 'columna' then
    update public.bingo_automatico
       set premio_columna_ganador_id = p_carton_ganador,
           premio_columna_ganador_nombre = v_ganadores_texto,
           premio_columna_pagado = true
     where id = p_juego_id;
  else
    update public.bingo_automatico
       set estado = 'finalizado', ganador_id = p_carton_ganador,
           ganador_nombre = v_ganadores_texto,
           premio_final_pagado = true, finalizado_en = now()
     where id = p_juego_id;
  end if;

  foreach v_numero in array v_ganadores loop
    select * into v_vendido from public.cartones_vendidos
     where numero_carton = v_numero;

    select * into v_usuario
      from public.usuarios_bingo
     where cedula = v_vendido.cedula
        or regexp_replace(cedula, '\\D', '', 'g') = regexp_replace(v_vendido.cedula, '\\D', '', 'g')
     order by (cedula = v_vendido.cedula) desc
     limit 1;
    if not found then raise exception 'Usuario no encontrado para carton %', v_numero; end if;

    select * into v_billetera from public.billeteras_bingo
     where usuario_id = v_usuario.id for update;
    if not found then raise exception 'Billetera no encontrada para usuario %', v_usuario.id; end if;

    v_saldo_anterior := v_billetera.saldo;
    v_saldo_nuevo := v_saldo_anterior + v_monto;
    update public.billeteras_bingo
       set saldo = v_saldo_nuevo, actualizada_en = now()
     where usuario_id = v_usuario.id;

    insert into public.billetera_movimientos (
      usuario_id, tipo, monto, saldo_anterior, saldo_nuevo, descripcion, referencia
    ) values (
      v_usuario.id, 'premio', v_monto, v_saldo_anterior, v_saldo_nuevo,
      'Premio ' || p_tipo_premio || ' carton #' || v_numero,
      'J' || p_juego_id || '-' || p_tipo_premio || '-' || v_numero
    );

    insert into public.bingo_premios_ganadores (
      juego_id, tipo_premio, numero_carton, nombre, cedula, telefono, monto_premio
    ) values (
      p_juego_id, p_tipo_premio, v_numero, v_vendido.nombre,
      v_vendido.cedula, v_vendido.telefono, v_monto
    ) on conflict (juego_id, tipo_premio, numero_carton) do nothing;

    insert into public.historial_ganadores (
      tipo_premio, nombre, cedula, telefono, numero_carton, juego_id
    )
    select p_tipo_premio, v_vendido.nombre, v_vendido.cedula,
           v_vendido.telefono, v_numero, p_juego_id
    where not exists (
      select 1 from public.historial_ganadores
       where juego_id = p_juego_id
         and tipo_premio = p_tipo_premio
         and numero_carton = v_numero
    );
  end loop;

  return jsonb_build_object(
    'ok', true, 'ganadores', v_ganadores,
    'monto_por_ganador', v_monto, 'total_ganadores', v_total,
    'ganadores_texto', v_ganadores_texto
  );
end;
$$;

revoke all on function public.bingo_reclamar_premio(bigint, text, integer, text, integer[], numeric) from public;
grant execute on function public.bingo_reclamar_premio(bigint, text, integer, text, integer[], numeric) to anon, authenticated;

notify pgrst, 'reload schema';

commit;

