-- Comprobantes WebP, referencias de 6 digitos e historial administrativo de pagos.
-- Migracion incremental: no altera solicitudes ni movimientos existentes.

begin;

create or replace function public.bingo_cliente_solicitar_recarga_seguro(
  p_token text, p_monto numeric, p_referencia text, p_comprobante_url text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_usuario_id integer; v_id bigint; v_limite jsonb; v_url text;
begin
  v_usuario_id := public.bingo_usuario_por_token(p_token);
  if v_usuario_id is null then
    return jsonb_build_object('ok', false, 'codigo', 'sesion_invalida');
  end if;

  v_limite := public.bingo_consumir_rate_limit(
    'solicitar_recarga', v_usuario_id::text, 6, 3600, 3600
  );
  if not coalesce((v_limite->>'permitido')::boolean, false) then
    return jsonb_build_object(
      'ok', false, 'codigo', 'rate_limit',
      'reintentar_en', v_limite->'reintentar_en'
    );
  end if;

  v_url := trim(coalesce(p_comprobante_url, ''));
  if coalesce(p_monto, 0) <= 0
     or p_monto > 100000000
     or coalesce(p_referencia, '') !~ '^[0-9]{6}$'
     or length(v_url) < 20
     or length(v_url) > 1000
     or position('/storage/v1/object/public/comprobantes/' in v_url) = 0
     or lower(split_part(v_url, '?', 1)) !~ '\.webp$' then
    return jsonb_build_object('ok', false, 'codigo', 'datos_invalidos');
  end if;

  insert into public.recargas_bingo
    (usuario_id, monto, referencia_pago, comprobante_url, estado)
  values
    (v_usuario_id, round(p_monto, 2), p_referencia, v_url, 'pendiente')
  returning id::bigint into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.bingo_admin_marcar_comprobante_recarga_eliminado_seguro(
  p_token text,
  p_recarga_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);

  update public.recargas_bingo
     set comprobante_url = null
   where id = p_recarga_id
     and estado in ('aprobado', 'rechazado');

  if not found then
    return jsonb_build_object('ok', false, 'codigo', 'recarga_no_procesada');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.bingo_admin_listar_movimientos_pago_seguro(p_token text)
returns table (
  tipo text,
  solicitud_id bigint,
  usuario_id integer,
  nombre text,
  cedula text,
  monto numeric,
  referencia text,
  estado text,
  solicitado_en timestamptz,
  procesado_en timestamptz,
  comprobante_url text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.bingo_admin_requerir_token(p_token);

  return query
    select movimientos.tipo,
           movimientos.solicitud_id,
           movimientos.usuario_id,
           movimientos.nombre,
           movimientos.cedula,
           movimientos.monto,
           movimientos.referencia,
           movimientos.estado,
           movimientos.solicitado_en,
           movimientos.procesado_en,
           movimientos.comprobante_url
      from (
        select 'recarga'::text as tipo,
               r.id::bigint as solicitud_id,
               r.usuario_id::integer as usuario_id,
               u.nombre::text as nombre,
               u.cedula::text as cedula,
               r.monto::numeric as monto,
               right(regexp_replace(coalesce(r.referencia_pago, ''), '\D', '', 'g'), 6)::text as referencia,
               r.estado::text as estado,
               r.solicitado_en::timestamptz as solicitado_en,
               r.procesado_en::timestamptz as procesado_en,
               r.comprobante_url::text as comprobante_url
          from public.recargas_bingo r
          join public.usuarios_bingo u on u.id = r.usuario_id
        union all
        select 'retiro'::text,
               r.id::bigint,
               r.usuario_id::integer,
               u.nombre::text,
               u.cedula::text,
               r.monto::numeric,
               null::text,
               r.estado::text,
               r.solicitado_en::timestamptz,
               r.procesado_en::timestamptz,
               null::text
          from public.retiros_bingo r
          join public.usuarios_bingo u on u.id = r.usuario_id
      ) movimientos
     order by coalesce(movimientos.procesado_en, movimientos.solicitado_en) desc
     limit 500;
end;
$$;

revoke all on function public.bingo_cliente_solicitar_recarga_seguro(text, numeric, text, text)
  from public, anon, authenticated;
revoke all on function public.bingo_admin_marcar_comprobante_recarga_eliminado_seguro(text, bigint)
  from public, anon, authenticated;
revoke all on function public.bingo_admin_listar_movimientos_pago_seguro(text)
  from public, anon, authenticated;

grant execute on function public.bingo_cliente_solicitar_recarga_seguro(text, numeric, text, text)
  to anon, authenticated;
grant execute on function public.bingo_admin_marcar_comprobante_recarga_eliminado_seguro(text, bigint)
  to anon, authenticated;
grant execute on function public.bingo_admin_listar_movimientos_pago_seguro(text)
  to anon, authenticated;

notify pgrst, 'reload schema';

commit;